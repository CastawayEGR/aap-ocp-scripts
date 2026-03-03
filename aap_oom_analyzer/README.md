# aap_oom_analyzer.py

AAP OOM root cause analyzer for OpenShift. Correlates kernel OOM events with AAP controller API data to identify which job templates and playbooks are causing OOM kills on task pods and job pods.

Supports offline analysis (sosreport bundles) and live cluster analysis (via `oc` CLI). No external Python dependencies required (stdlib only, Python 3.6+).

## Features

- **AAP-aware OOM detection** - Separately tracks task pod OOMs (execution environment pods) and job pod OOMs (`receptor`/`worker` pods)
- **Job correlation** - Matches OOM events against running AAP jobs via the controller API to identify the responsible playbook/template
- **Frequency analysis** - Ranks job templates by OOM frequency to surface repeat offenders
- **Memory profiling** - Shows cgroup memory usage vs. limits, per-process RSS breakdown, and awx-manage worker counts
- **Actionable recommendations** - Provides root-cause analysis and tuning guidance based on OOM patterns
- **Auto-discovery** - Detects the AAP controller URL from cluster routes when namespace is provided
- **Deduplication** - Tracks pods by UID, container ID, and name to avoid reporting the same event twice

## Requirements

- Python 3.6+
- **Live mode:** `oc` (logged in to the cluster), `jq`
- **Offline mode:** sosreport bundle(s) containing `sos_commands/kernel/dmesg_-T` and `sos_commands/openshift/journalctl_--no-pager_--unit_kubelet`

## Usage

### Live mode (default — no `-d` flag)

Queries the cluster for OOMKilled/Evicted pods, fetches kernel logs and kubelet journals from worker nodes, and optionally correlates with the AAP API.

```bash
# Basic scan — finds OOM events but no playbook correlation
python3 aap_oom_analyzer.py -n aap-namespace

# With AAP API correlation (identifies which playbooks caused OOMs)
python3 aap_oom_analyzer.py -n aap-namespace \
  -c https://controller.example.com -t <oauth-token>

# Using environment variables for API credentials
export AAP_CONTROLLER_URL=https://controller.example.com
export AAP_TOKEN=<oauth-token>
python3 aap_oom_analyzer.py -n aap-namespace

# Only analyze OOMs from the last 48 hours
python3 aap_oom_analyzer.py -n aap-namespace -T 48

# Verbose — show full kernel OOM reports, per-process RSS, kubelet logs
python3 aap_oom_analyzer.py -n aap-namespace -v
```

### Offline mode (sosreport analysis)

Analyzes sosreport bundles. Automatically discovers sosreport directories by locating `sos_commands/kernel/dmesg_-T` files. Can still correlate with the AAP API or a pre-exported jobs JSON file.

```bash
# Sosreport analysis only (no playbook correlation)
python3 aap_oom_analyzer.py -d /path/to/sosreports/

# With pre-exported jobs JSON for offline correlation
python3 aap_oom_analyzer.py -d /path/to/sosreports/ -f jobs.json

# With live API correlation against offline OOM data
python3 aap_oom_analyzer.py -d /path/to/sosreports/ \
  -c https://controller.example.com -t <token>

# Filter to a specific namespace
python3 aap_oom_analyzer.py -d /path/to/sosreports/ -n aap

# Verbose output
python3 aap_oom_analyzer.py -d /path/to/sosreports/ -v
```

### Exporting jobs JSON for offline use

If you have API access now but will analyze sosreports later, export the jobs data first:

```bash
curl -sk -H "Authorization: Bearer $AAP_TOKEN" \
  "https://controller.example.com/api/v2/jobs/?page_size=200" > jobs.json

# Then later, use with sosreport analysis
python3 aap_oom_analyzer.py -d /path/to/sosreports/ -f jobs.json
```

## Options

| Flag | Description |
|------|-------------|
| `-d <directory>` | Path to sosreport(s) — triggers offline mode |
| `-c <url>` | AAP controller URL (or `AAP_CONTROLLER_URL` env var) |
| `-t <token>` | OAuth token (or `AAP_TOKEN` env var) |
| `-f <jobs.json>` | Pre-exported jobs JSON file (alternative to live API) |
| `-n <namespace>` | AAP namespace filter (live mode: also used for auto-discovering controller URL) |
| `-T <hours>` | Only analyze OOMs from last N hours (ignored in offline mode) |
| `-v` | Verbose: show full kernel OOM reports, per-process RSS, kubelet/CRI-O logs |
| `-h` | Display help |

## Exit Codes

| Code | Meaning |
|------|---------|
| 0 | OOM events found |
| 1 | No OOM events found |
| 2 | Error (missing tools, bad arguments, etc.) |

## Output Sections

### Without API (`-c`/`-t`/`-f` not provided)

1. **Task Pod OOM Timeline** - Chronological table of task pod OOM kills with timestamp, type, node, pod name, memory limit/usage, worker count, and max worker RSS
2. **Job Pod OOM Summary** - Table of job pod OOM kills with timestamp, type, job ID, memory limit, and killed process RSS
3. **Fallback guidance** - Shows how to re-run with API credentials for full correlation, including example `curl` commands to export job data

### With API correlation

1. **Task Pod OOM Timeline** - Same as above
2. **Job Template Frequency Analysis** - Ranks job templates by how often they appear on OOM'd task pods, with playbook paths and correlation percentages
3. **Affected Jobs by Task Pod OOM** - Per-pod breakdown of which jobs were running on each OOM'd task pod, with root-cause classification (task pod OOM, eviction, job pod OOM, etc.)
4. **Job Pod OOM Summary** - Enriched with template name and playbook from the API
5. **Memory Profile** - Min/max/avg RSS at OOM time, grouped by template
6. **Recommendations** - Actionable suggestions: likely root cause template, root-cause breakdown of failed jobs, memory tuning advice (task pod limits, forks, Container Group pod_spec_override)

## How It Works

1. **Discovery** - In offline mode, recursively finds sosreport directories. In live mode, queries `oc get pods` for OOMKilled/Evicted pods and fetches kernel logs from worker nodes.
2. **Kernel OOM parsing** - Scans `dmesg` for `CONSTRAINT_MEMCG` OOM kill events, extracts cgroup paths, and maps pod UIDs/container IDs back to pod names via the kubelet journal.
3. **Eviction parsing** - Scans kubelet journal for `eviction_manager` entries to find pods evicted due to node memory pressure.
4. **Categorization** - Separates events into task pod OOMs (pods with `-task-` in the name) and job pod OOMs (pods with `automation-job-` in the name).
5. **API correlation** - When configured, queries the AAP controller API to match OOM events with running jobs. Primary method: `controller_node` lookup (which task pod ran each job). Fallback: timestamp window matching.
6. **Reporting** - Displays tables, frequency analysis, and recommendations with color-coded output.
