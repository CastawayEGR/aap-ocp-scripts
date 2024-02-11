OpenShift Ansible Automation Platform Job Log Extractor
=========
[![License: MIT](https://img.shields.io/badge/License-MIT-brightgreen.svg)](https://opensource.org/licenses/MIT)
[![GitHub repo size in bytes](https://img.shields.io/github/repo-size/CastawayEGR/aap-ocp-scripts.svg?logoColor=brightgreen)](https://github.com/CastawayEGR/aap-ocp-scripts)
[![GitHub last commit](https://img.shields.io/github/last-commit/CastawayEGR/aap-ocp-scripts.svg?logoColor=brightgreen)](https://github.com/CastawayEGR/aap-ocp-scripts)

This Bash script extracts logs related to Ansible Automation Platform (AAP) job pods running on OpenShift from the worker nodes where the jobs are executed. It's particularly useful for identifying and troubleshooting issues, especially related to out-of-memory (OOM) events within the job pods.

## Usage

```bash
./aap_job_log_extractor.sh -s <job_id> [-n <namespace>] [-h]
```

### Options

- `-s <job_id>`: Specifies the AAP job ID to search for.
- `-n <namespace>`: (Optional) Specifies the namespace AAP jobs are run to search within. If not provided, searches across all namespaces.
- `-h`: Displays the help menu.

## Examples

### Search for job logs across all namespaces:

```bash
./aap_job_log_extractor.sh -s 12345
```

### Search for job logs within a specific namespace:

```bash
./aap_job_log_extractor.sh -s 12345 -n aap
```

### Display help menu:

```bash
./aap_job_log_extractor.sh -h
```

## How It Works

The script utilizes the OpenShift CLI (`oc`) to retrieve events related to the specified job ID. It then extracts logs from the worker nodes where the job pods are executed, particularly focusing on identifying OOM events and providing relevant logs for analysis.

## Requirements

- OpenShift CLI (`oc`) must be installed and configured.
- `jq` must be installed.

## License

[MIT](https://choosealicense.com/licenses/mit/)
