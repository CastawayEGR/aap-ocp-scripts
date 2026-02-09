OpenShift Ansible Automation Platform Job Log Extractor
=========
[![License: MIT](https://img.shields.io/badge/License-MIT-brightgreen.svg)](https://opensource.org/licenses/MIT)
[![GitHub repo size in bytes](https://img.shields.io/github/repo-size/CastawayEGR/aap-ocp-scripts.svg?logoColor=brightgreen)](https://github.com/CastawayEGR/aap-ocp-scripts)
[![GitHub last commit](https://img.shields.io/github/last-commit/CastawayEGR/aap-ocp-scripts.svg?logoColor=brightgreen)](https://github.com/CastawayEGR/aap-ocp-scripts)

This Bash script extracts logs related to Ansible Automation Platform (AAP) job pods running on OpenShift from the worker nodes where the jobs are executed. It's particularly useful for identifying and troubleshooting issues, especially related to out-of-memory (OOM) events within the job pods.

The script supports two modes:
- **Live mode**: Queries a live OpenShift cluster using `oc` commands (default).
- **Offline mode**: Analyzes pre-collected sosreport data from worker nodes using the `-d` flag. This is useful for post-incident analysis, sharing diagnostics with support teams, or working in disconnected environments.

## Usage

```bash
# Live mode
./aap_job_log_extractor.sh -s <job_id> [-n <namespace>] [-h]

# Offline mode (sosreport analysis)
./aap_job_log_extractor.sh -s <job_id> -d <directory> [-h]
```

### Options

- `-s <job_id>`: Specifies the AAP job ID to search for (must be numeric).
- `-n <namespace>`: (Optional, live mode only) Specifies the namespace AAP jobs are run to search within. If not provided, searches across all namespaces.
- `-d <directory>`: Path to a directory containing extracted sosreport(s). Sosreport directories are discovered recursively. When provided, the script operates entirely offline.
- `-h`: Displays the help menu.

## Examples

### Live mode - search for job logs across all namespaces:

```bash
./aap_job_log_extractor.sh -s 12345
```

### Live mode - search for job logs within a specific namespace:

```bash
./aap_job_log_extractor.sh -s 12345 -n aap
```

### Offline mode - analyze sosreports for a specific job:

```bash
./aap_job_log_extractor.sh -s 4 -d /path/to/diagnostics/sos-reports
```

### Offline mode - search recursively from a parent directory:

```bash
./aap_job_log_extractor.sh -s 7 -d /path/to/diagnostics
```

### Display help menu:

```bash
./aap_job_log_extractor.sh -h
```

## How It Works

### Live Mode

The script utilizes the OpenShift CLI (`oc`) to retrieve events related to the specified job ID. It then extracts logs from the worker nodes where the job pods are executed, particularly focusing on identifying OOM events and providing relevant logs for analysis.

### Offline Mode

The script recursively discovers extracted sosreport directories under the given path by looking for the kubelet journal file (`sos_commands/openshift/journalctl_--no-pager_--unit_kubelet`). It then:

1. Searches each sosreport's kubelet journal for the specified job ID.
2. Extracts the container ID using a tiered approach (kubelet kill events, container finished events, or PLEG startup events).
3. Displays container logs from the kubelet journal.
4. If available, displays CRI-O application logs (`sos_commands/crio/containers/logs/crictl_logs_-t_<container_id>`).
5. Checks for eviction events in the kubelet journal and kernel OOM kills in `dmesg_-T`.

Sosreport directories must be pre-extracted (`.tar.xz` archives are not automatically handled).

## Requirements

### Live Mode
- OpenShift CLI (`oc`) must be installed and configured.
- `jq` must be installed.

### Offline Mode
- No external tools required beyond standard bash utilities.
- Extracted sosreport directories with kubelet journal data.

## Color Output

When run in a terminal, the script highlights matched values (job ID, container ID, `oom-kill`, `eviction`) inline within log output for easier scanning. Color is automatically disabled when output is piped or redirected. Set `NO_COLOR=1` to disable color explicitly.

## License

[MIT](https://choosealicense.com/licenses/mit/)
