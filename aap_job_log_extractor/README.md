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
Usage: aap_job_log_extractor.sh [OPTIONS] JOB_ID [JOB_ID ...]

  JOB_ID              One or more numeric job IDs (positional)

  Live mode (default):
    -j <job_id>       Specify a job ID (repeatable, alternative to positional)
    -n <namespace>    Namespace where AAP jobs run (default: all)
    -l <label>        Node label selector to restrict node search
                      (e.g., node-role.kubernetes.io/aap-worker=)

  Offline mode:
    -d <directory>    Path to extracted sosreport(s)

  -h                  Display this help message
```

### Options

- **Positional JOB_IDs**: One or more numeric job IDs passed as positional arguments.
- `-j <job_id>`: (Repeatable) Specify a job ID. Can be combined with positional arguments; duplicates are automatically removed.
- `-n <namespace>`: (Optional, live mode only) Specifies the namespace AAP jobs are run to search within. If not provided, searches across all namespaces.
- `-l <label>`: (Optional, live mode only) Node label selector to restrict the brute-force node search. Defaults to `node-role.kubernetes.io/worker`. Useful for clusters with dedicated AAP worker nodes.
- `-d <directory>`: Path to a directory containing extracted sosreport(s). Sosreport directories are discovered recursively. When provided, the script operates entirely offline.
- `-h`: Displays the help menu.

### Exit Codes

| Situation | Code |
|-----------|------|
| All jobs found | 0 |
| No jobs found | 1 |
| Some jobs found, some not | 2 |
| Usage/infrastructure error | 1 |

## Examples

### Live mode - search for a single job:

```bash
./aap_job_log_extractor.sh 12345
```

### Live mode - search for multiple jobs:

```bash
./aap_job_log_extractor.sh 12345 12346 12347
```

### Live mode - using the -j flag (repeatable):

```bash
./aap_job_log_extractor.sh -j 12345 -j 12346
```

### Live mode - mixed positional and -j:

```bash
./aap_job_log_extractor.sh -j 12345 12346 12347
```

### Live mode - restrict node search with a label selector:

```bash
./aap_job_log_extractor.sh -l node-role.kubernetes.io/aap-worker= 12345 12346
```

### Live mode - search within a specific namespace:

```bash
./aap_job_log_extractor.sh -n aap 12345
```

### Offline mode - analyze sosreports for multiple jobs:

```bash
./aap_job_log_extractor.sh -d /path/to/diagnostics/sos-reports 4 7 12
```

### Display help menu:

```bash
./aap_job_log_extractor.sh -h
```

## How It Works

### Live Mode

The script uses a node-centric architecture to efficiently process multiple jobs:

1. **Phase 1 — Event resolution**: Fetches cluster events once and uses `jq` to find each job's assigned node, building a node-to-jobs map.
2. **Phase 2 — Brute-force resolution**: For jobs not found in events, iterates through worker nodes (filtered by `-l` label selector if provided), fetching each node's journal once and searching for all remaining unresolved jobs. Journals are cached to avoid redundant fetches.
3. **Phase 3 — Processing**: For each node with assigned jobs, extracts container IDs and displays logs, OOM detection, and eviction information.
4. **Phase 4 — Summary**: When processing multiple jobs, prints a summary showing how many were found and lists any missing job IDs.

This approach avoids redundantly fetching the same node's journal multiple times when investigating several jobs that ran on the same node.

### Offline Mode

The script recursively discovers extracted sosreport directories under the given path by looking for the kubelet journal file (`sos_commands/openshift/journalctl_--no-pager_--unit_kubelet`). It then:

1. Searches each sosreport's kubelet journal for the specified job ID.
2. Extracts the container ID using a tiered approach (kubelet kill events, container finished events, or PLEG startup events).
3. Displays container logs from the kubelet journal.
4. If available, displays CRI-O application logs (`sos_commands/crio/containers/logs/crictl_logs_-t_<container_id>`).
5. Checks for eviction events in the kubelet journal and kernel OOM kills in `dmesg_-T`, falling back to the boot journal (`sos_commands/logs/journalctl_--no-pager_--boot`) when the dmesg ring buffer has rotated.

Sosreport directories must be pre-extracted (`.tar.xz` archives are not automatically handled).

### Understanding kernel OOM output

When a pod is killed by the kernel for exceeding its **memory limit**, the limit applies to the **entire cgroup** (all processes in the container), not just one process. The script reports:

- **Process Memory (killed)**: The single process the OOM killer chose as the victim (e.g. one `ansible-playboo` with ~1.8GB). That is why you may see "1.8GB" for the process but "6GB" for the cgroup.
- **Cgroup Memory**: Total usage and limit for the container (all processes combined).
- **Tasks in cgroup**: When the kernel OOM report includes a "Tasks state" dump, the script parses it and shows RSS by process name (e.g. 6× ansible-playboo, 37× ssh). This makes it clear that many processes together reached the limit—typical for AAP jobs with multiple playbook workers and SSH connections. The script supports both kernel task-line formats (e.g. `[1484104]` and `[  49040]`, where the pid may be right-padded with spaces), so names and RSS display correctly across different kernel/sosreport versions.

  **Are those processes really in the same pod?** Yes. For a cgroup OOM (`constraint=CONSTRAINT_MEMCG`), the kernel only dumps tasks that belong to the OOM cgroup. In `mm/oom_kill.c`, `dump_tasks()` calls `mem_cgroup_scan_tasks(oc->memcg, dump_task, oc)` when `is_memcg_oom(oc)` is true, so the "Tasks state" list is exactly the processes in the container that hit the limit—no other pods or processes are included.

### Node Label Selector

The `-l` flag allows you to restrict the brute-force node search (Phase 2) to nodes matching a specific label. This is useful for clusters with dedicated or tainted AAP worker nodes:

```bash
# Only search nodes labeled as AAP workers
./aap_job_log_extractor.sh -l node-role.kubernetes.io/aap-worker= 12345

# Search nodes with a custom label
./aap_job_log_extractor.sh -l workload=aap 12345 12346
```

If no nodes match the label selector, the script exits with an error. The label selector does not affect event-based resolution (Phase 1), which trusts the event data regardless. In offline mode, `-l` is ignored with a warning.

## Requirements

- **Bash 4+** is required (associative arrays, `mapfile`). On macOS the default Bash is 3.x; use a newer Bash (e.g. from Homebrew) or run on Linux/RHEL.

### Live Mode
- OpenShift CLI (`oc`) must be installed and configured.
- `jq` must be installed.

### Offline Mode
- No external tools required beyond standard bash utilities.
- Extracted sosreport directories with kubelet journal data.

### Verifying output (same results after changes)

Run with Bash 4+ on old data, new data, and live to confirm identical behaviour:

```bash
bash aap_job_log_extractor.sh -d test_data/ -j 11115312
bash aap_job_log_extractor.sh -d test_data/new/ -j 4
bash aap_job_log_extractor.sh -j 3 -j 4
```

## Color Output

When run in a terminal, the script highlights matched values (job ID, container ID, `oom-kill`, `eviction`) inline within log output for easier scanning. Color is automatically disabled when output is piped or redirected. Set `NO_COLOR=1` to disable color explicitly.

## License

[MIT](https://choosealicense.com/licenses/mit/)

