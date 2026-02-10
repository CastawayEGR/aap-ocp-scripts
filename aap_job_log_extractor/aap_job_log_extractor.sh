#!/bin/bash
# Script to gather Ansible Automation Platform job pod logs from OpenShift nodes.
# Particularly useful for finding out if a pod was OOM killed without taking a full sosreport.
# Supports offline analysis of pre-collected sosreport data via the -d flag.
# Supports multiple job IDs and node label selectors for targeted node searches.
# Author: Michael Tipton

# --- Temp directory lifecycle ---
SCRIPT_TMPDIR=$(mktemp -d) || { echo "Error: Failed to create temp directory." >&2; exit 1; }
trap 'rm -rf "$SCRIPT_TMPDIR"' EXIT

# --- Color setup ---
# Respects NO_COLOR (https://no-color.org/) and detects non-terminal output.
setup_colors() {
    if [[ -t 1 ]] && [[ -z "${NO_COLOR:-}" ]]; then
        RED=$'\e[31m'
        GREEN=$'\e[32m'
        YELLOW=$'\e[33m'
        HIGHLIGHT=$'\e[1;33m'
        RESET=$'\e[0m'
    else
        RED=''
        GREEN=''
        YELLOW=''
        HIGHLIGHT=''
        RESET=''
    fi
}

# Highlight matched terms in piped log output.
# Usage: echo "$logs" | highlight_output "term1" "term2" ...
highlight_output() {
    if [[ -z "$HIGHLIGHT" ]]; then
        cat
        return
    fi
    local sed_args=()
    for term in "$@"; do
        [[ -n "$term" ]] && sed_args+=(-e "s|${term}|${HIGHLIGHT}${term}${RESET}|g")
    done
    if [[ ${#sed_args[@]} -eq 0 ]]; then
        cat
        return
    fi
    sed "${sed_args[@]}"
}

setup_colors

# Convert kB value to human-readable format with MB/GB suffix.
format_kb() {
    local kb="$1"
    if [[ ! "$kb" =~ ^[0-9]+$ ]]; then
        echo "${kb}kB"
        return
    fi
    if [[ "$kb" -ge 1048576 ]]; then
        printf '%skB (%.1fGB)\n' "$kb" "$(awk "BEGIN {printf \"%.1f\", $kb/1048576}")"
    elif [[ "$kb" -ge 1024 ]]; then
        echo "${kb}kB ($((kb / 1024))MB)"
    else
        echo "${kb}kB"
    fi
}

# Extract and display memory summary from a kernel OOM event.
# Parses the "Killed process" line for per-process memory and searches
# backwards from the oom-kill line for cgroup usage/limit.
display_oom_memory() {
    local source_file="$1"
    local pid="$2"
    local container_id="$3"

    # Per-process memory from "Killed process" line
    local killed_line
    killed_line=$(grep "Killed process $pid " "$source_file" | head -1)
    if [[ -n "$killed_line" ]]; then
        local total_vm anon_rss file_rss shmem_rss
        total_vm=$(grep -oP 'total-vm:\K[0-9]+' <<< "$killed_line")
        anon_rss=$(grep -oP 'anon-rss:\K[0-9]+' <<< "$killed_line")
        file_rss=$(grep -oP 'file-rss:\K[0-9]+' <<< "$killed_line")
        shmem_rss=$(grep -oP 'shmem-rss:\K[0-9]+' <<< "$killed_line")

        echo "${RED}Process Memory (killed):${RESET}"
        [[ -n "$total_vm" ]] && echo "  Total VM:  $(format_kb "$total_vm")"
        [[ -n "$anon_rss" ]] && echo "  Anon RSS:  $(format_kb "$anon_rss")"
        [[ -n "$file_rss" ]] && echo "  File RSS:  $(format_kb "$file_rss")"
        [[ -n "$shmem_rss" ]] && echo "  Shmem RSS: $(format_kb "$shmem_rss")"
    fi

    # Cgroup memory from "memory: usage" line within the same OOM report.
    # Find the oom-kill: line for our container, then search backward for
    # "invoked oom-killer" to locate the report's start boundary.  This avoids
    # a fixed lookback window that can miss data when the process list is large.
    local oom_line_num
    oom_line_num=$(grep -n "oom-kill.*${container_id}" "$source_file" | head -1 | cut -d: -f1)
    if [[ -n "$oom_line_num" ]]; then
        local report_start
        report_start=$(sed -n "1,${oom_line_num}p" "$source_file" | grep -n "invoked oom-killer" | tail -1 | cut -d: -f1)
        if [[ -n "$report_start" ]]; then
            local mem_line
            mem_line=$(sed -n "${report_start},${oom_line_num}p" "$source_file" | grep "memory: usage" | tail -1)
            if [[ -n "$mem_line" ]]; then
                local usage limit failcnt
                usage=$(grep -oP 'usage \K[0-9]+' <<< "$mem_line" | head -1)
                limit=$(grep -oP 'limit \K[0-9]+' <<< "$mem_line" | head -1)
                failcnt=$(grep -oP 'failcnt \K[0-9]+' <<< "$mem_line")

                echo "${RED}Cgroup Memory:${RESET}"
                [[ -n "$usage" ]] && echo "  Usage:     $(format_kb "$usage")"
                [[ -n "$limit" ]] && echo "  Limit:     $(format_kb "$limit")"
                [[ -n "$failcnt" ]] && echo "  Failcnt:   $failcnt"
            fi
        fi
    fi
}

usage() {
    echo "Usage: $0 [OPTIONS] JOB_ID [JOB_ID ...]"
    echo ""
    echo "  JOB_ID              One or more numeric job IDs (positional)"
    echo ""
    echo "  Live mode (default):"
    echo "    -j <job_id>       Specify a job ID (repeatable, alternative to positional)"
    echo "    -n <namespace>    Namespace where AAP jobs run (default: all)"
    echo "    -l <label>        Node label selector to restrict node search"
    echo "                      (e.g., node-role.kubernetes.io/aap-worker=)"
    echo ""
    echo "  Offline mode:"
    echo "    -d <directory>    Path to extracted sosreport(s)"
    echo ""
    echo "  -h                  Display this help message"
    exit 1
}

# --- Output formatting ---

print_job_separator() {
    local job_id="$1"
    local index="$2"
    local total="$3"
    if [[ "$total" -gt 1 ]]; then
        [[ "$index" -gt 1 ]] && echo ""
        echo "========================================================================"
        echo " Job $job_id ($index/$total)"
        echo "========================================================================"
        echo ""
    fi
}

print_summary() {
    local found_count="$1"
    local total="$2"
    shift 2
    local -a missing_list=("$@")

    if [[ "$total" -le 1 ]]; then
        return
    fi

    echo ""
    echo "========================================================================"
    echo " Summary: $found_count/$total jobs found"
    echo "========================================================================"
    if [[ ${#missing_list[@]} -gt 0 ]]; then
        echo "${RED}Not found:${RESET} ${missing_list[*]}" >&2
    fi
}

# --- Sosreport discovery ---

discover_sosreports() {
    local search_dir="$1"
    local -A seen
    while IFS= read -r kubelet_journal; do
        local sos_root
        sos_root=$(dirname "$(dirname "$(dirname "$kubelet_journal")")")
        if [[ -z "${seen[$sos_root]+x}" ]]; then
            seen[$sos_root]=1
            echo "$sos_root"
        fi
    done < <(find "$search_dir" -type f -name "journalctl_--no-pager_--unit_kubelet" \
        -path "*/sos_commands/openshift/*" 2>/dev/null)
}

get_node_from_sosreport() {
    local sos_root="$1"
    # Primary: read hostname file
    if [[ -f "$sos_root/sos_commands/host/hostname" ]]; then
        head -1 "$sos_root/sos_commands/host/hostname" | tr -d '[:space:]'
        return
    fi
    # Fallback: parse from directory name (sosreport-<hostname>-<date>-...)
    local dirname
    dirname=$(basename "$sos_root")
    echo "$dirname" | sed -E 's/^sosreport-//;s/-[0-9]{4}-[0-9]{2}-[0-9]{2}-.*//'
}

# --- Offline processing ---

process_logs_offline() {
    local sos_root="$1"
    local jobid="$2"
    local kubelet_journal="$sos_root/sos_commands/openshift/journalctl_--no-pager_--unit_kubelet"
    local dmesg_file="$sos_root/sos_commands/kernel/dmesg_-T"
    local node
    node=$(get_node_from_sosreport "$sos_root")

    # Tier 1: containerName="worker" containerID="cri-o://{64hex}" (kubelet actively kills container)
    local aap_job_cid
    aap_job_cid=$(grep -- "job-${jobid}" "$kubelet_journal" | \
        grep -oP 'containerName="worker"\s+containerID="cri-o://\K[a-f0-9]{64}' | head -1)

    # Extract pod UUID from kubelet journal (PLEG events, topology_manager, etc.)
    local pod_uid
    pod_uid=$(grep -- "job-${jobid}" "$kubelet_journal" | \
        grep -oP '"ID":"?\K[a-f0-9]{8}(-[a-f0-9]{4}){3}-[a-f0-9]{12}' | head -1)

    # Tier 2: use pod UUID to find "container finished" line (references pod by UUID, not name)
    if [[ -z "$aap_job_cid" ]] && [[ -n "$pod_uid" ]]; then
        aap_job_cid=$(grep 'container finished' "$kubelet_journal" | grep "$pod_uid" | \
            grep -oP 'containerID="\K[a-f0-9]{64}' | head -1)
    fi

    # Tier 3: PLEG ContainerStarted "Data":"{64hex}" (always present, may have multiple)
    if [[ -z "$aap_job_cid" ]]; then
        local -a candidates
        mapfile -t candidates < <(grep -- "job-${jobid}" "$kubelet_journal" | \
            grep 'ContainerStarted' | grep -oP '"Data":"?\K[a-f0-9]{64}')

        if [[ ${#candidates[@]} -eq 1 ]]; then
            aap_job_cid="${candidates[0]}"
        elif [[ ${#candidates[@]} -gt 1 ]] && [[ -f "$dmesg_file" ]]; then
            # Disambiguate: check which container ID appears in dmesg oom-kill cgroup paths
            for cid in "${candidates[@]}"; do
                if grep -q "oom-kill" "$dmesg_file" && grep "oom-kill" "$dmesg_file" | grep -qF "$cid"; then
                    aap_job_cid="$cid"
                    break
                fi
            done
            # If no OOM match, take the first candidate (first started is typically worker)
            if [[ -z "$aap_job_cid" ]]; then
                aap_job_cid="${candidates[0]}"
            fi
        elif [[ ${#candidates[@]} -gt 1 ]]; then
            aap_job_cid="${candidates[0]}"
        fi
    fi

    if [[ -z "$aap_job_cid" ]]; then
        return 1
    fi

    local highlight_terms=("job-${jobid}" "$aap_job_cid" "oom-kill" "eviction")

    echo "${RED}Job ID:${RESET} ${HIGHLIGHT}${jobid}${RESET}"
    echo "${RED}Node:${RESET} $node"
    echo "${RED}Source:${RESET} sosreport at $(basename "$sos_root")"
    echo ""
    echo "${RED}Container ID:${RESET} ${HIGHLIGHT}${aap_job_cid}${RESET}"
    echo "${RED}Container Logs (kubelet):${RESET}"
    grep -F "$aap_job_cid" "$kubelet_journal" | highlight_output "${highlight_terms[@]}"

    # CRI-O application logs if available
    local crio_log="$sos_root/sos_commands/crio/containers/logs/crictl_logs_-t_${aap_job_cid}"
    if [[ -f "$crio_log" ]] && [[ -s "$crio_log" ]]; then
        echo ""
        echo "${RED}Container Application Logs (crio):${RESET}"
        highlight_output "${highlight_terms[@]}" < "$crio_log"
    fi

    # Check for eviction in kubelet journal
    local eviction
    eviction=$(grep 'eviction_manager' "$kubelet_journal" | grep -- "job-${jobid}")

    # Check for kernel OOM in dmesg, then fall back to boot journal
    local kernel_oom=""
    local oom_source=""
    if [[ -f "$dmesg_file" ]]; then
        kernel_oom=$(grep 'oom-kill' "$dmesg_file" | grep -F "$aap_job_cid")
        [[ -n "$kernel_oom" ]] && oom_source="$dmesg_file"
    fi

    # Fallback: check full boot journal (journald persists kernel messages beyond dmesg ring buffer)
    if [[ -z "$kernel_oom" ]]; then
        local boot_journal="$sos_root/sos_commands/logs/journalctl_--no-pager_--boot"
        if [[ -f "$boot_journal" ]]; then
            kernel_oom=$(grep 'oom-kill' "$boot_journal" | grep -F "$aap_job_cid")
            [[ -n "$kernel_oom" ]] && oom_source="$boot_journal"
        fi
    fi

    if [[ -z "$kernel_oom" ]] && [[ ! -f "$dmesg_file" ]]; then
        echo ""
        echo "${YELLOW}Warning: dmesg_-T not found; kernel OOM detection limited to kubelet journal.${RESET}"
    fi

    if [[ -n "$eviction" ]]; then
        echo ""
        echo "${RED}OOM Type:${RESET} Eviction (node under memory pressure)"
        echo "${RED}Eviction Logs:${RESET}"
        echo "$eviction" | highlight_output "${highlight_terms[@]}"
    elif [[ -n "$kernel_oom" ]]; then
        echo ""
        echo "${RED}OOM Type:${RESET} Kernel OOM Kill (pod exceeded memory limit)"
        local pid
        pid=$(grep -oP 'pid=\K\d+' <<< "$kernel_oom")
        echo "${RED}PID:${RESET} $pid"
        display_oom_memory "$oom_source" "$pid" "$aap_job_cid"
        echo "${RED}OOM Logs:${RESET}"
        grep -F "$pid" "$oom_source" | highlight_output "${highlight_terms[@]}" "$pid"
    else
        echo ""
        echo "${GREEN}No OOM detected for this job.${RESET}"
    fi

    return 0
}

# --- Live mode functions ---

# Fetch a node's journal to the cache. Reuses cached file if already fetched.
# Sets NODE_JOURNAL_CACHE[$node] to the cached file path.
# Returns 1 on fetch failure.
fetch_node_journal() {
    local node="$1"

    # Reuse cache if already fetched
    if [[ -n "${NODE_JOURNAL_CACHE[$node]+x}" ]]; then
        return 0
    fi

    local safe_name="${node//\//_}"
    local tmpfile="$SCRIPT_TMPDIR/journal_${safe_name}"

    if ! oc adm node-logs "$node" --path=journal > "$tmpfile" 2>&1; then
        echo "Error: Failed to fetch journal from node $node." >&2
        return 1
    fi

    NODE_JOURNAL_CACHE[$node]="$tmpfile"
    return 0
}

# Search for a job in an already-fetched journal file.
# Outputs all results (container ID, logs, OOM detection).
# Returns 1 if job not found in journal.
search_job_in_journal() {
    local journal_file="$1"
    local jobid="$2"
    local node="$3"

    local aap_job_cid
    aap_job_cid=$(grep -oP 'Created container [^:]+:.*-job-'"$jobid"'-[a-z0-9]+/' "$journal_file" | grep -oP '[a-f0-9]{64}')

    if [[ -z "$aap_job_cid" ]]; then
        return 1
    fi

    local highlight_terms=("job-${jobid}" "$aap_job_cid" "oom-kill" "eviction")

    echo "${RED}Job ID:${RESET} ${HIGHLIGHT}${jobid}${RESET}"
    echo "${RED}Node:${RESET} $node"
    echo ""
    echo "${RED}Container ID:${RESET} ${HIGHLIGHT}${aap_job_cid}${RESET}"
    echo "${RED}Container Logs:${RESET}"
    grep -F "$aap_job_cid" "$journal_file" | highlight_output "${highlight_terms[@]}"

    # Note: In live mode, oc adm node-logs --path=journal returns the full systemd journal,
    # which includes kernel messages (journald imports them by default on RHCOS).
    # This differs from offline mode where only the kubelet-filtered journal is available.
    local kernel_oom
    kernel_oom=$(grep 'oom-kill' "$journal_file" | grep -F "$aap_job_cid")
    local eviction
    eviction=$(grep 'eviction_manager' "$journal_file" | grep -- "job-${jobid}")

    if [[ -n "$eviction" ]]; then
        echo ""
        echo "${RED}OOM Type:${RESET} Eviction (node under memory pressure)"
        echo "${RED}Eviction Logs:${RESET}"
        echo "$eviction" | highlight_output "${highlight_terms[@]}"
    elif [[ -n "$kernel_oom" ]]; then
        echo ""
        echo "${RED}OOM Type:${RESET} Kernel OOM Kill (pod exceeded memory limit)"
        local pid
        pid=$(grep -oP 'pid=\K\d+' <<< "$kernel_oom")
        echo "${RED}PID:${RESET} $pid"
        display_oom_memory "$journal_file" "$pid" "$aap_job_cid"
        echo "${RED}OOM Logs:${RESET}"
        grep -F "$pid" "$journal_file" | highlight_output "${highlight_terms[@]}" "$pid"
    else
        echo ""
        echo "${GREEN}No OOM detected for this job.${RESET}"
    fi

    return 0
}

# Phase 1: Resolve jobs to nodes via cluster events.
# Populates NODE_TO_JOBS, JOB_TO_NODE; remaining go to UNRESOLVED_JOBS.
resolve_jobs_from_events() {
    local event_json="$1"
    shift
    local -a job_ids=("$@")

    for jobid in "${job_ids[@]}"; do
        local node
        node=$(jq -r --arg jobid "$jobid" \
            '.items[] | select(.message | test("assigned.*job-\($jobid)")).message' \
            <<< "$event_json" | awk '{ print $5 }' | head -1)

        if [[ -n "$node" ]]; then
            JOB_TO_NODE[$jobid]="$node"
            if [[ -n "${NODE_TO_JOBS[$node]+x}" ]]; then
                NODE_TO_JOBS[$node]+=" $jobid"
            else
                NODE_TO_JOBS[$node]="$jobid"
            fi
        else
            UNRESOLVED_JOBS+=("$jobid")
        fi
    done
}

# Phase 2: Brute-force resolve remaining jobs by fetching node journals.
# Updates NODE_TO_JOBS, JOB_TO_NODE; removes resolved from UNRESOLVED_JOBS.
bruteforce_resolve_jobs() {
    local node_label="${NODE_LABEL_SELECTOR:-node-role.kubernetes.io/worker}"

    local worker_nodes
    worker_nodes=$(oc get nodes -l "$node_label" -o jsonpath='{.items[*].metadata.name}') || {
        echo "Error: Failed to fetch nodes with label '$node_label'." >&2
        exit 1
    }
    if [[ -z "$worker_nodes" ]]; then
        echo "Error: No nodes found matching label '$node_label'." >&2
        exit 1
    fi

    for node in $worker_nodes; do
        if [[ ${#UNRESOLVED_JOBS[@]} -eq 0 ]]; then
            break
        fi

        if ! fetch_node_journal "$node"; then
            continue
        fi

        local journal_file="${NODE_JOURNAL_CACHE[$node]}"
        local -a still_unresolved=()

        for jobid in "${UNRESOLVED_JOBS[@]}"; do
            if grep -qP 'Created container [^:]+:.*-job-'"$jobid"'-[a-z0-9]+/' "$journal_file"; then
                JOB_TO_NODE[$jobid]="$node"
                if [[ -n "${NODE_TO_JOBS[$node]+x}" ]]; then
                    NODE_TO_JOBS[$node]+=" $jobid"
                else
                    NODE_TO_JOBS[$node]="$jobid"
                fi
            else
                still_unresolved+=("$jobid")
            fi
        done

        UNRESOLVED_JOBS=("${still_unresolved[@]}")
    done
}

# --- Argument parsing ---

declare -a JOB_IDS_RAW=()
namespace=""
sosreport_dir=""
NODE_LABEL_SELECTOR=""

while getopts "j:n:d:l:h" flag; do
    case "${flag}" in
        j) JOB_IDS_RAW+=("$OPTARG") ;;
        n) namespace="$OPTARG" ;;
        d) sosreport_dir="$OPTARG" ;;
        l) NODE_LABEL_SELECTOR="$OPTARG" ;;
        h) usage ;;
        *) usage ;;
    esac
done
shift $((OPTIND - 1))

# Append positional arguments
JOB_IDS_RAW+=("$@")

if [[ ${#JOB_IDS_RAW[@]} -eq 0 ]]; then
    echo "Error: At least one job ID is required." >&2
    usage
fi

# Validate all job IDs are numeric
for id in "${JOB_IDS_RAW[@]}"; do
    if ! [[ "$id" =~ ^[0-9]+$ ]]; then
        echo "Error: Job ID must be numeric, got '$id'" >&2
        exit 1
    fi
done

# Deduplicate job IDs while preserving order
declare -A SEEN_IDS
declare -a JOB_IDS=()
for id in "${JOB_IDS_RAW[@]}"; do
    if [[ -z "${SEEN_IDS[$id]+x}" ]]; then
        SEEN_IDS[$id]=1
        JOB_IDS+=("$id")
    fi
done
unset SEEN_IDS

total=${#JOB_IDS[@]}
found_count=0
declare -a missing_jobs=()

if [[ -n "${sosreport_dir}" ]]; then
    # --- Offline mode ---
    if [[ -n "${namespace}" ]]; then
        echo "${YELLOW}Warning: -n (namespace) is ignored in offline mode.${RESET}" >&2
    fi
    if [[ -n "${NODE_LABEL_SELECTOR}" ]]; then
        echo "${YELLOW}Warning: -l (node label selector) is ignored in offline mode.${RESET}" >&2
    fi

    if [[ ! -d "$sosreport_dir" ]]; then
        echo "Error: Directory '$sosreport_dir' does not exist." >&2
        exit 1
    fi

    mapfile -t sos_roots < <(discover_sosreports "$sosreport_dir")

    if [[ ${#sos_roots[@]} -eq 0 ]]; then
        echo "Error: No sosreport directories found under '$sosreport_dir'." >&2
        echo "Expected structure: <dir>/sos_commands/openshift/journalctl_--no-pager_--unit_kubelet" >&2
        exit 1
    fi

    index=0
    for jobid in "${JOB_IDS[@]}"; do
        index=$((index + 1))
        print_job_separator "$jobid" "$index" "$total"

        job_found=false
        for sos_root in "${sos_roots[@]}"; do
            kubelet_journal="$sos_root/sos_commands/openshift/journalctl_--no-pager_--unit_kubelet"
            if grep -q -- "job-${jobid}" "$kubelet_journal" 2>/dev/null; then
                if process_logs_offline "$sos_root" "$jobid"; then
                    job_found=true
                    break
                fi
            fi
        done

        if [[ "$job_found" == "true" ]]; then
            found_count=$((found_count + 1))
        else
            echo "Error: No job with id $jobid found in ${#sos_roots[@]} sosreport(s) searched." >&2
            missing_jobs+=("$jobid")
        fi
    done

    print_summary "$found_count" "$total" "${missing_jobs[@]}"
else
    # --- Live mode ---
    if ! command -v oc &>/dev/null; then
        echo "Error: 'oc' command not found. Please make sure OpenShift CLI is installed and in your PATH." >&2
        exit 1
    fi

    if ! command -v jq &>/dev/null; then
        echo "Error: 'jq' command not found. Please make sure 'jq' is installed and in your PATH." >&2
        exit 1
    fi

    # Data structures for node-centric processing
    declare -A NODE_TO_JOBS
    declare -A JOB_TO_NODE
    declare -a UNRESOLVED_JOBS=()
    declare -A NODE_JOURNAL_CACHE

    # Phase 1: Event resolution
    local_event_json=""
    if [[ -z "${namespace}" ]]; then
        local_event_json=$(oc get events -o json) || { echo "Error: Failed to fetch cluster events." >&2; exit 1; }
    else
        local_event_json=$(oc get events -n "$namespace" -o json) || { echo "Error: Failed to fetch events from namespace '$namespace'." >&2; exit 1; }
    fi

    resolve_jobs_from_events "$local_event_json" "${JOB_IDS[@]}"

    # Phase 2: Brute-force resolution for unresolved jobs
    if [[ ${#UNRESOLVED_JOBS[@]} -gt 0 ]]; then
        bruteforce_resolve_jobs
    fi

    # Phase 3: Process all resolved jobs, node by node
    declare -A PROCESSED_JOBS
    index=0
    for node in "${!NODE_TO_JOBS[@]}"; do
        if ! fetch_node_journal "$node"; then
            # Mark all jobs on this node as missing
            for jobid in ${NODE_TO_JOBS[$node]}; do
                if [[ -z "${PROCESSED_JOBS[$jobid]+x}" ]]; then
                    PROCESSED_JOBS[$jobid]=1
                    missing_jobs+=("$jobid")
                fi
            done
            continue
        fi

        journal_file="${NODE_JOURNAL_CACHE[$node]}"

        for jobid in ${NODE_TO_JOBS[$node]}; do
            if [[ -n "${PROCESSED_JOBS[$jobid]+x}" ]]; then
                continue
            fi
            PROCESSED_JOBS[$jobid]=1
            index=$((index + 1))
            print_job_separator "$jobid" "$index" "$total"

            if search_job_in_journal "$journal_file" "$jobid" "$node"; then
                found_count=$((found_count + 1))
            else
                echo "Error: No job with id $jobid found on node $node." >&2
                missing_jobs+=("$jobid")
            fi
        done
    done

    # Any jobs still in UNRESOLVED_JOBS after brute-force are missing
    for jobid in "${UNRESOLVED_JOBS[@]}"; do
        if [[ -z "${PROCESSED_JOBS[$jobid]+x}" ]]; then
            PROCESSED_JOBS[$jobid]=1
            index=$((index + 1))
            print_job_separator "$jobid" "$index" "$total"
            echo "Error: No job with id $jobid found on any worker node." >&2
            missing_jobs+=("$jobid")
        fi
    done

    # Phase 4: Summary
    print_summary "$found_count" "$total" "${missing_jobs[@]}"
fi

# Exit codes: 0 = all found, 1 = none found, 2 = partial
if [[ "$found_count" -eq "$total" ]]; then
    exit 0
elif [[ "$found_count" -eq 0 ]]; then
    exit 1
else
    exit 2
fi
