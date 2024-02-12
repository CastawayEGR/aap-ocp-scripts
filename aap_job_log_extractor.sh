#!/bin/bash
# Script to gather an Ansible Automation Platform job pod logs from OpenShift nodes.
# Particularly useful for finding out if a pod was OOM killed without taking a full sosreport. 
# Author: Michael Tipton


usage() {
    echo "Usage: $0 -s <job_id> [-n <namespace>]"
    echo "  -s <job_id>     Specify the job ID to search for"
    echo "  -n <namespace>  Optional: Specify the namespace where AAP jobs run (default is all namespaces)"
    echo "  -h              Display this help message"
    exit 1
}

# Check if 'oc' binary exists
if ! command -v oc &>/dev/null; then
    echo "Error: 'oc' command not found. Please make sure OpenShift CLI is installed and in your PATH."
    exit 1
fi

# Check if 'jq' binary exists
if ! command -v jq &>/dev/null; then
    echo "Error: 'jq' command not found. Please make sure 'jq' is installed and in your PATH."
    exit 1
fi

process_logs() {
    local node="$1"
    #local logs=$(oc debug node/"$node" -q -- bash -c 'chroot /host journalctl')
    local logs=$(oc adm node-logs "$node" --path=journal)
    local aap_job_cid=$(echo "$logs" | grep -oP 'Created container [^:]+:.*-job-'"$jobid"'-[a-z0-9]+/' | grep -oP '[a-f0-9]{64}')
    if [[ -n "$aap_job_cid" ]]; then
        echo -e "\e[31mJob ID:\e[0m $jobid\n\e[31mNode:\e[0m $node\n\n\e[31mContainer ID:\e[0m $aap_job_cid\n\e[31mContainer Logs:\e[0m"
        grep -F "$aap_job_cid" <<< "$logs"
    else
        echo "Error: No job with id $jobid found."
        exit
    fi
    local pid=$(echo "$logs" | grep 'oom-kill' | grep -oP 'pid=\K\d+')
    if [[ -n "$pid" ]]; then
        echo -e "\n\e[31mPID:\e[0m $pid\n\e[31mPID Logs:\e[0m"
        grep -F "$pid" <<< "$logs"
    fi
}

while getopts "s:n:h" flag; do
    case "${flag}" in
        s) jobid=${OPTARG} ;;
        n) namespace=${OPTARG} ;;
        h) usage ;;
        *) usage ;;
    esac
done

if [[ -z "$jobid" ]]; then
    echo "Error: Missing job id parameter (-s)"
    usage
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

