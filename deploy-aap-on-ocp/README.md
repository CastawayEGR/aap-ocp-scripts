# OpenShift Ansible Automation Platform (AAP) Installer

[](https://opensource.org/licenses/MIT)

This Bash script automates the installation and removal of Ansible Automation Platform (AAP) on an OpenShift Container Platform (OCP) cluster. It handles the creation of the namespace, installation of the operator (with manual approval), and optional deployment of the AAP instance.

The script can automatically fetch the latest compatible operator version (CSV) from an external compatibility matrix, simplifying the installation process. It also provides a robust cleanup function to remove the operator, CRDs, and namespace.

## Usage

```bash
# To install
./deploy-aap-on-ocp.sh <version> [namespace] [flags]

# To clean
./deploy-aap-on-ocp.sh [namespace] --clean
```

## Arguments & Flags

### Required Argument (for Install)

  * `<version>`: The AAP version to install. Must be `2.4`, `2.5`, or `2.6`.

### Optional Argument

  * `[namespace]`: The namespace to install into or clean. (Default: `aap`).

### Flags

  * `-h, --help`: Show the help message.
  * `--clean`: Deletes the namespace, all `ansible` CRDs (cluster-wide), and the operator. This is a destructive action and will prompt for confirmation.
  * `--deploy`: After the operator is installed, this flag proceeds to deploy the AAP custom resource (i.e., the Controller/Hub/EDA instance).
  * `--cluster-scoped`: Installs the operator in cluster-scoped mode instead of the default namespace-scoped mode.
  * `--csv <csv_name>`: Manually specify the operator CSV name, skipping the automatic fetching mechanism.

## Examples

### Install AAP 2.4 in the default 'aap' namespace

```bash
./deploy-aap-on-ocp.sh 2.4
```

### Install AAP 2.5 in 'my-aap' namespace and deploy the instance

```bash
./deploy-aap-on-ocp.sh 2.5 my-aap --deploy
```

### Install the cluster-scoped operator for AAP 2.6

```bash
./deploy-aap-on-ocp.sh 2.6 --cluster-scoped
```

### Clean up the default 'aap' namespace

```bash
./deploy-aap-on-ocp.sh --clean
```

### Clean up a custom 'my-aap' namespace

```bash
./deploy-aap-on-ocp.sh my-aap --clean
```

## How It Works

### Installation

1.  Parses arguments to determine the desired AAP version, namespace, scope, and flags.
2.  Fetches the latest compatible CSV name from the [aap-openshift-compatibility-matrix](https://www.google.com/search?q=https://github.com/lennysh/aap-openshift-compatibility-matrix) repo, unless a specific CSV is provided with the `--csv` flag.
3.  Creates the target namespace and an `OperatorGroup`.
4.  Creates a `Subscription` resource with `installPlanApproval: Manual` and the specific `startingCSV` that was fetched or provided.
5.  Polls the cluster until the `InstallPlan` resource is generated.
6.  Patches the `InstallPlan` to `{"spec":{"approved":true}}` to begin the operator installation.
7.  Waits for the operator's CSV to report a `Succeeded` phase.
8.  If `--deploy` is used, it applies the appropriate `AnsibleAutomationPlatform` (for 2.5/2.6) or `AutomationController` (for 2.4) custom resource to provision the AAP instance.

### Cleanup

1.  Prompts the user for confirmation before proceeding.
2.  Deletes the target project/namespace.
3.  Deletes all `ansible` CustomResourceDefinitions (CRDs) from the cluster.
4.  Deletes the operator subscription.

## Requirements

  * **OpenShift CLI (`oc`)**: Must be installed, configured, and logged into a cluster.
  * **Cluster-admin privileges**: Required for creating/deleting cluster-scoped CRDs and installing operators.
  * **`curl`**: Used to fetch the latest CSV information.
  * **`awk`**, **`grep`**, **`tail`**, **`tr`**: Standard shell utilities used for parsing.

## License

[MIT](https://choosealicense.com/licenses/mit/)
