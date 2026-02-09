#!/bin/bash
# Script to gather an Ansible Automation Platform job pod logs from OpenShift nodes.
# Particularly useful for finding out if a pod was OOM killed without taking a full sosreport.
# Supports offline analysis of pre-collected sosreport data via the -d flag.
# Author: Michael Tipton

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

usage() {
    echo "Usage: $0 -s <job_id> [-n <namespace>] [-d <directory>] [-h]"
    echo ""
    echo "  Live mode (default):"
    echo "    -s <job_id>     Specify the job ID to search for"
    echo "    -n <namespace>  Optional: Specify the namespace where AAP jobs run (default is all namespaces)"
    echo ""
    echo "  Offline mode (sosreport analysis):"
    echo "    -s <job_id>     Specify the job ID to search for"
    echo "    -d <directory>  Path to directory containing extracted sosreport(s)"
    echo "                    Sosreport directories are discovered recursively"
    echo ""
    echo "  -h                Display this help message"
    exit 1
}

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

process_logs_offline() {
    local sos_root="$1"
    local kubelet_journal="$sos_root/sos_commands/openshift/journalctl_--no-pager_--unit_kubelet"
    local dmesg_file="$sos_root/sos_commands/kernel/dmesg_-T"
    local node
    node=$(get_node_from_sosreport "$sos_root")

    # Tier 1: containerName="worker" containerID="cri-o://{64hex}" (kubelet actively kills container)
    local aap_job_cid
    aap_job_cid=$(grep -- "job-${jobid}" "$kubelet_journal" | \
        grep -oP 'containerName="worker"\s+containerID="cri-o://\K[a-f0-9]{64}' | head -1)

    # Tier 2: generic.go "container finished" containerID="{64hex}" (container exits any reason)
    if [[ -z "$aap_job_cid" ]]; then
        aap_job_cid=$(grep -- "job-${jobid}" "$kubelet_journal" | \
            grep 'container finished' | grep -oP 'containerID="\K[a-f0-9]{64}' | head -1)
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
            # If no OOM match, take the last candidate (last started is typically worker)
            if [[ -z "$aap_job_cid" ]]; then
                aap_job_cid="${candidates[-1]}"
            fi
        elif [[ ${#candidates[@]} -gt 1 ]]; then
            aap_job_cid="${candidates[-1]}"
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

    # Check for kernel OOM in dmesg
    local kernel_oom=""
    if [[ -f "$dmesg_file" ]]; then
        kernel_oom=$(grep 'oom-kill' "$dmesg_file" | grep -F "$aap_job_cid")
    else
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
        echo "${RED}OOM Logs:${RESET}"
        grep -F "$pid" "$dmesg_file" | highlight_output "${highlight_terms[@]}" "$pid"
    else
        echo ""
        echo "${GREEN}No OOM detected for this job.${RESET}"
    fi

    return 0
}

process_logs() {
    local node="$1"
    local tmpfile
    tmpfile=$(mktemp) || { echo "Error: Failed to create temp file."; return 1; }
    # shellcheck disable=SC2064
    trap "rm -f '$tmpfile'" RETURN

    if ! oc adm node-logs "$node" --path=journal > "$tmpfile" 2>&1; then
        echo "Error: Failed to fetch journal from node $node."
        return 1
    fi

    local aap_job_cid
    aap_job_cid=$(grep -oP 'Created container [^:]+:.*-job-'"$jobid"'-[a-z0-9]+/' "$tmpfile" | grep -oP '[a-f0-9]{64}')

    if [[ -z "$aap_job_cid" ]]; then
        return 1
    fi

    local highlight_terms=("job-${jobid}" "$aap_job_cid" "oom-kill" "eviction")

    echo "${RED}Job ID:${RESET} ${HIGHLIGHT}${jobid}${RESET}"
    echo "${RED}Node:${RESET} $node"
    echo ""
    echo "${RED}Container ID:${RESET} ${HIGHLIGHT}${aap_job_cid}${RESET}"
    echo "${RED}Container Logs:${RESET}"
    grep -F "$aap_job_cid" "$tmpfile" | highlight_output "${highlight_terms[@]}"

    # Note: In live mode, oc adm node-logs --path=journal returns the full systemd journal,
    # which includes kernel messages (journald imports them by default on RHCOS).
    # This differs from offline mode where only the kubelet-filtered journal is available.
    local kernel_oom
    kernel_oom=$(grep 'oom-kill' "$tmpfile" | grep -F "$aap_job_cid")
    local eviction
    eviction=$(grep 'eviction_manager' "$tmpfile" | grep -- "job-${jobid}")

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
        echo "${RED}OOM Logs:${RESET}"
        grep -F "$pid" "$tmpfile" | highlight_output "${highlight_terms[@]}" "$pid"
    else
        echo ""
        echo "${GREEN}No OOM detected for this job.${RESET}"
    fi

    return 0
}

# --- Argument parsing ---
while getopts "s:n:d:h" flag; do
    case "${flag}" in
        s) jobid=${OPTARG} ;;
        n) namespace=${OPTARG} ;;
        d) sosreport_dir=${OPTARG} ;;
        h) usage ;;
        *) usage ;;
    esac
done

if [[ -z "${jobid:-}" ]]; then
    echo "Error: Missing job id parameter (-s)"
    usage
fi

# Validate job ID is numeric
if ! [[ "$jobid" =~ ^[0-9]+$ ]]; then
    echo "Error: Job ID must be numeric, got '$jobid'"
    exit 1
fi

if [[ -n "${sosreport_dir:-}" ]]; then
    # Offline mode: analyze sosreport data
    if [[ -n "${namespace:-}" ]]; then
        echo "${YELLOW}Warning: -n (namespace) is ignored in offline mode.${RESET}"
    fi

    if [[ ! -d "$sosreport_dir" ]]; then
        echo "Error: Directory '$sosreport_dir' does not exist."
        exit 1
    fi

    mapfile -t sos_roots < <(discover_sosreports "$sosreport_dir")

    if [[ ${#sos_roots[@]} -eq 0 ]]; then
        echo "Error: No sosreport directories found under '$sosreport_dir'."
        echo "Expected structure: <dir>/sos_commands/openshift/journalctl_--no-pager_--unit_kubelet"
        exit 1
    fi

    found=false
    for sos_root in "${sos_roots[@]}"; do
        kubelet_journal="$sos_root/sos_commands/openshift/journalctl_--no-pager_--unit_kubelet"
        if grep -q -- "job-${jobid}" "$kubelet_journal" 2>/dev/null; then
            process_logs_offline "$sos_root"
            found=true
            break
        fi
    done

    if [[ "$found" != "true" ]]; then
        echo "Error: No job with id $jobid found in ${#sos_roots[@]} sosreport(s) searched."
        exit 1
    fi
else
    # Live mode: requires oc and jq
    if ! command -v oc &>/dev/null; then
        echo "Error: 'oc' command not found. Please make sure OpenShift CLI is installed and in your PATH."
        exit 1
    fi

    if ! command -v jq &>/dev/null; then
        echo "Error: 'jq' command not found. Please make sure 'jq' is installed and in your PATH."
        exit 1
    fi

    if [[ -z "${namespace:-}" ]]; then
        event_json=$(oc get events -o json) || { echo "Error: Failed to fetch cluster events."; exit 1; }
    else
        event_json=$(oc get events -n "$namespace" -o json) || { echo "Error: Failed to fetch events from namespace '$namespace'."; exit 1; }
    fi

    aap_worker_node=$(jq -r --arg jobid "$jobid" '.items[] | select(.message | test("assigned.*job-\($jobid)")).message' <<< "$event_json" | awk '{ print $5 }')

    if [[ -z "$aap_worker_node" ]]; then
        worker_nodes=$(oc get nodes -l node-role.kubernetes.io/worker -o jsonpath={.items[*].metadata.name}) || {
            echo "Error: Failed to fetch worker nodes."
            exit 1
        }
        if [[ -z "$worker_nodes" ]]; then
            echo "Error: No worker nodes found."
            exit 1
        fi
        found=false
        for node in $worker_nodes; do
            if process_logs "$node"; then
                found=true
                break
            fi
        done
        if [[ "$found" != "true" ]]; then
            echo "Error: No job with id $jobid found on any worker node."
            exit 1
        fi
    else
        if ! process_logs "$aap_worker_node"; then
            echo "Error: No job with id $jobid found on node $aap_worker_node."
            exit 1
        fi
    fi
fi

exit 0
