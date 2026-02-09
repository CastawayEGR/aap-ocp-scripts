#!/bin/bash
# Script to gather an Ansible Automation Platform job pod logs from OpenShift nodes.
# Particularly useful for finding out if a pod was OOM killed without taking a full sosreport.
# Supports offline analysis of pre-collected sosreport data via the -d flag.
# Author: Michael Tipton


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
    while IFS= read -r kubelet_journal; do
        dirname "$(dirname "$(dirname "$kubelet_journal")")"
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
    aap_job_cid=$(grep "job-${jobid}" "$kubelet_journal" | \
        grep -oP 'containerName="worker"\s+containerID="cri-o://\K[a-f0-9]{64}' | head -1)

    # Tier 2: generic.go "container finished" containerID="{64hex}" (container exits any reason)
    if [[ -z "$aap_job_cid" ]]; then
        aap_job_cid=$(grep "job-${jobid}" "$kubelet_journal" | \
            grep 'container finished' | grep -oP 'containerID="\K[a-f0-9]{64}' | head -1)
    fi

    # Tier 3: PLEG ContainerStarted "Data":"{64hex}" (always present, may have multiple)
    if [[ -z "$aap_job_cid" ]]; then
        local -a candidates
        mapfile -t candidates < <(grep "job-${jobid}" "$kubelet_journal" | \
            grep 'ContainerStarted' | grep -oP '"Data":"?\K[a-f0-9]{64}')

        if [[ ${#candidates[@]} -eq 1 ]]; then
            aap_job_cid="${candidates[0]}"
        elif [[ ${#candidates[@]} -gt 1 ]] && [[ -f "$dmesg_file" ]]; then
            # Disambiguate by checking which ID appears in dmesg oom-kill
            for cid in "${candidates[@]}"; do
                if grep -q "oom-kill" "$dmesg_file" && grep "oom-kill" "$dmesg_file" | grep -qF "$cid"; then
                    aap_job_cid="$cid"
                    break
                fi
            done
            # If no OOM match, take the first non-redis candidate (last started is typically worker)
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

    echo -e "\e[31mJob ID:\e[0m $jobid"
    echo -e "\e[31mNode:\e[0m $node"
    echo -e "\e[31mSource:\e[0m sosreport at $(basename "$sos_root")"
    echo ""
    echo -e "\e[31mContainer ID:\e[0m $aap_job_cid"
    echo -e "\e[31mContainer Logs (kubelet):\e[0m"
    grep -F "$aap_job_cid" "$kubelet_journal"

    # Bonus: CRI-O application logs if available
    local crio_log="$sos_root/sos_commands/crio/containers/logs/crictl_logs_-t_${aap_job_cid}"
    if [[ -f "$crio_log" ]] && [[ -s "$crio_log" ]]; then
        echo ""
        echo -e "\e[31mContainer Application Logs (crio):\e[0m"
        cat "$crio_log"
    fi

    # Check for eviction in kubelet journal
    local eviction
    eviction=$(grep 'eviction_manager' "$kubelet_journal" | grep "job-${jobid}")

    # Check for kernel OOM in dmesg
    local kernel_oom=""
    if [[ -f "$dmesg_file" ]]; then
        kernel_oom=$(grep 'oom-kill' "$dmesg_file" | grep -F "$aap_job_cid")
    else
        echo -e "\n\e[33mWarning: dmesg_-T not found; kernel OOM detection limited to kubelet journal.\e[0m"
    fi

    if [[ -n "$eviction" ]]; then
        echo -e "\n\e[31mOOM Type:\e[0m Eviction (node under memory pressure)"
        echo -e "\e[31mEviction Logs:\e[0m"
        echo "$eviction"
    elif [[ -n "$kernel_oom" ]]; then
        echo -e "\n\e[31mOOM Type:\e[0m Kernel OOM Kill (pod exceeded memory limit)"
        local pid
        pid=$(grep -oP 'pid=\K\d+' <<< "$kernel_oom")
        echo -e "\e[31mPID:\e[0m $pid"
        echo -e "\e[31mOOM Logs:\e[0m"
        grep -F "$pid" "$dmesg_file"
    else
        echo -e "\n\e[32mNo OOM detected for this job.\e[0m"
    fi
}

process_logs() {
    local node="$1"
    local logs=$(oc adm node-logs "$node" --path=journal)
    local aap_job_cid=$(echo "$logs" | grep -oP 'Created container [^:]+:.*-job-'"$jobid"'-[a-z0-9]+/' | grep -oP '[a-f0-9]{64}')
    if [[ -n "$aap_job_cid" ]]; then
        echo -e "\e[31mJob ID:\e[0m $jobid\n\e[31mNode:\e[0m $node\n\n\e[31mContainer ID:\e[0m $aap_job_cid\n\e[31mContainer Logs:\e[0m"
        grep -F "$aap_job_cid" <<< "$logs"
    else
        echo "Error: No job with id $jobid found."
        exit
    fi
    # Kernel OOM: oom-kill referencing this container's cgroup
    local kernel_oom=$(grep 'oom-kill' <<< "$logs" | grep -F "$aap_job_cid")
    # Eviction: kubelet eviction_manager referencing this job pod
    local eviction=$(grep 'eviction_manager' <<< "$logs" | grep "job-${jobid}")

    if [[ -n "$eviction" ]]; then
        echo -e "\n\e[31mOOM Type:\e[0m Eviction (node under memory pressure)"
        echo -e "\e[31mEviction Logs:\e[0m"
        echo "$eviction"
    elif [[ -n "$kernel_oom" ]]; then
        echo -e "\n\e[31mOOM Type:\e[0m Kernel OOM Kill (pod exceeded memory limit)"
        local pid=$(grep -oP 'pid=\K\d+' <<< "$kernel_oom")
        echo -e "\e[31mPID:\e[0m $pid\n\e[31mOOM Logs:\e[0m"
        grep -F "$pid" <<< "$logs"
    else
        echo -e "\n\e[32mNo OOM detected for this job.\e[0m"
    fi
}

while getopts "s:n:d:h" flag; do
    case "${flag}" in
        s) jobid=${OPTARG} ;;
        n) namespace=${OPTARG} ;;
        d) sosreport_dir=${OPTARG} ;;
        h) usage ;;
        *) usage ;;
    esac
done

if [[ -z "$jobid" ]]; then
    echo "Error: Missing job id parameter (-s)"
    usage
fi

if [[ -n "$sosreport_dir" ]]; then
    # Offline mode: analyze sosreport data
    if [[ -n "$namespace" ]]; then
        echo -e "\e[33mWarning: -n (namespace) is ignored in offline mode.\e[0m"
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
        if grep -q "job-${jobid}" "$kubelet_journal" 2>/dev/null; then
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

    if [[ -z "$namespace" ]]; then
        event_json=$(oc get events -o json)
    else
        event_json=$(oc get events -n "$namespace" -o json)
    fi

    aap_worker_node=$(jq -r --arg jobid "$jobid" '.items[] | select(.message | test("assigned.*job-\($jobid)")).message' <<< "$event_json" | awk '{ print $5 }')

    if [[ -z "$aap_worker_node" ]]; then
        worker_nodes=$(oc get nodes -l node-role.kubernetes.io/worker -o jsonpath={.items[*].metadata.name})
        if [[ -z "$worker_nodes" ]]; then
            echo "Error: No worker nodes found."
            exit 1
        fi
        for node in $worker_nodes; do
            process_logs "$node"
            exit
        done
    else
        process_logs "$aap_worker_node"
    fi
fi
