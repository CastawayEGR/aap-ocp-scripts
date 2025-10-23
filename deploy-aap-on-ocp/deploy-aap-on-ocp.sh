
#!/bin/bash

# --- Helper Functions ---

usage() {
    # Use $0 to be dynamic (e.g., ./aap-ocp.sh or bash aap-ocp.sh)
    echo "Usage: $0 <version> [namespace] [flags]"
    echo "   or: $0 [namespace] --clean"
    echo ""
    echo "Required Arguments (for install):"
    echo "  <version>             Specify '2.4', '2.5', or '2.6'"
    echo ""
    echo "Optional Arguments:"
    echo "  [namespace]           The namespace to install into or clean. (Default: 'aap')"
    echo ""
    echo "Flags:"
    echo "  -h, --help            Show this help message."
    echo "  --clean               Delete the namespace, 'ansible' CRDs, and operator. Runs before install."
    echo "  --deploy              Optional. Deploys the AAP instance after operator install."
    echo "  --cluster-scoped      Optional. Fetch the latest 'Cluster-scoped' CSV and use the cluster-scoped channel."
    echo "  --csv <csv_name>      Optional. Manually specify the AAP_CSV_NAME, skipping the automatic fetch."
    echo ""
    echo "Examples:"
    echo "  $0 2.4"
    echo "  $0 2.5 my-aap --deploy"
    echo "  $0 2.6 --cluster-scoped"
    echo "  $0 --clean"
    echo "  $0 my-aap --clean"
}

fetch_latest_csv() {
    local url="$1"
    local scope_flag="$2"
    
    # ---
    # The first column "Release Date" (e.g., "October 21, 2025") contains a comma,
    # which shifts the field indices for awk.
    #
    # $1 = "October 21"
    # $2 = " 2025"
    # $3 = "aap-operator..." (Cluster-scoped)
    # $4 = "aap-operator..." (Namespace-scoped)
    # ---
    local col_index=4 # Default to column 4 for Namespace-scoped

    if [[ "$scope_flag" == "--cluster-scoped" ]]; then
        col_index=3 # Column 3 for Cluster-scoped
    fi

    echo "Fetching CSV list from $url..." >&2

    # 1. Get the file
    # 2. Filter out any blank lines
    # 3. Get the very last line
    # 4. Get the Nth column (3 or 4) using ',' as the delimiter
    local latest_csv
    latest_csv=$(curl -sL "$url" | grep -v '^\s*$' | tail -n 1 | awk -F ',' -v idx="$col_index" '{print $idx}')

    if [[ -z "$latest_csv" ]]; then
        echo "Error: Could not find CSV value in column $col_index from $url" >&2
        return
    fi
    
    # Trim whitespace, carriage returns, and any potential quotes
    latest_csv=$(echo "$latest_csv" | tr -d '[:space:]' | tr -d '"')
    
    echo "$latest_csv"
}


# --- Argument Parsing ---

# Handle no args or --help first
if [[ $# -eq 0 ]]; then
    usage
    exit 0
fi

# Defaults
AAP_VERSION=""
AAP_NAMESPACE="aap"
DEPLOY_FLAG=""
SCOPE_FLAG="--namespace-scoped" # Default
CSV_OVERRIDE=""
CLEAN_FLAG=""

# Parse all arguments
while [[ $# -gt 0 ]]; do
    case "$1" in
        -h|--help)
            usage
            exit 0
            ;;
        --clean)
            CLEAN_FLAG="true"
            shift # consume the flag
            ;;
        2.4|2.5|2.6)
            if [[ -n "$AAP_VERSION" ]]; then
                echo "Error: Version already set to $AAP_VERSION. Cannot set to $1." >&2
                usage >&2
                exit 1
            fi
            AAP_VERSION="$1"
            shift # consume the version
            ;;
        --deploy)
            DEPLOY_FLAG="--deploy"
            shift # consume the flag
            ;;
        --cluster-scoped)
            SCOPE_FLAG="--cluster-scoped"
            shift # consume the flag
            ;;
        --csv)
            if [[ -z "$2" ]]; then
                echo "Error: --csv flag requires a CSV name argument." >&2
                usage >&2
                exit 1
            fi
            CSV_OVERRIDE="$2"
            shift 2 # consume the flag and its argument
            ;;
        -*)
            echo "Error: Unknown flag $1" >&2
            usage >&2
            exit 1
            ;;
        *)
            # This handles the case where 'aap' is explicitly provided,
            # or a custom namespace is given.
            if [[ "$AAP_NAMESPACE" != "aap" && "$1" != "$AAP_NAMESPACE" ]]; then
                echo "Error: Namespace already set to $AAP_NAMESPACE. Cannot also set to $1." >&2
                usage >&2
                exit 1
            fi
            AAP_NAMESPACE="$1"
            shift # consume the namespace
            ;;
    esac
done

# --- Handle --clean action ---
if [[ "$CLEAN_FLAG" == "true" ]]; then
    echo "--- Cleaning up installation in namespace '$AAP_NAMESPACE' ---"
    
    echo "WARNING: This will delete the project '$AAP_NAMESPACE', all 'ansible' CRDs (cluster-wide), and the operator."
    read -p "Are you sure you want to continue? (y/N): " confirm
    if [[ "$confirm" != "y" && "$confirm" != "Y" ]]; then
        echo "Cleanup aborted."
        exit 0
    fi

    echo "Deleting project '$AAP_NAMESPACE'..."
    oc delete project "$AAP_NAMESPACE"

    echo "Deleting all 'ansible' CRDs (cluster-wide)..."
    oc get crds | grep ansible | awk '{print $1}' | xargs oc delete crd
    
    echo "Deleting operator 'ansible-automation-platform-operator.$AAP_NAMESPACE'..."
    oc delete operator "ansible-automation-platform-operator.$AAP_NAMESPACE"

    echo "Cleanup finished."
    exit 0
fi

# Check required args (now only triggers if --clean was not used)
if [[ -z "$AAP_VERSION" ]]; then
    echo "Error: Version (2.4, 2.5, or 2.6) is required for installation." >&2
    usage >&2
    exit 1
fi


# --- Version-Specific Settings ---
URL_BASE="https://raw.githubusercontent.com/lennysh/aap-openshift-compatibility-matrix/main/data"
CSV_FILENAME=""

if [[ "$AAP_VERSION" == "2.6" ]]; then
    OPERATOR_CHANNEL="stable-2.6"
    CSV_FILENAME="AAP_26.csv"
elif [[ "$AAP_VERSION" == "2.5" ]]; then
    OPERATOR_CHANNEL="stable-2.5"
    CSV_FILENAME="AAP_25.csv"
elif [[ "$AAP_VERSION" == "2.4" ]]; then
    OPERATOR_CHANNEL="stable-2.4"
    CSV_FILENAME="AAP_24.csv"
fi

# --- Set AAP_CSV_NAME (Manual or Fetched) ---
AAP_CSV_NAME=""

if [[ -n "$CSV_OVERRIDE" ]]; then
    echo "Using manually provided CSV: $CSV_OVERRIDE"
    AAP_CSV_NAME="$CSV_OVERRIDE"
    
    # Adjust channel name if cluster-scoped is manually specified (CSV override)
    if [[ "$SCOPE_FLAG" == "--cluster-scoped" ]]; then
        OPERATOR_CHANNEL="${OPERATOR_CHANNEL}-cluster-scoped"
        echo "Note: Using cluster-scoped channel for manual CSV."
    fi
else
    # Adjust channel name and log message based on scope
    if [[ "$SCOPE_FLAG" == "--cluster-scoped" ]]; then
        OPERATOR_CHANNEL="${OPERATOR_CHANNEL}-cluster-scoped"
        echo "Attempting to fetch latest CSV for $AAP_VERSION (Cluster-scoped)..."
    else
        echo "Attempting to fetch latest CSV for $AAP_VERSION (Namespace-scoped)..."
    fi
    
    FETCH_URL="$URL_BASE/$CSV_FILENAME"
    
    AAP_CSV_NAME=$(fetch_latest_csv "$FETCH_URL" "$SCOPE_FLAG")
    
    if [[ -z "$AAP_CSV_NAME" ]]; then
        echo "Error: Failed to fetch latest CSV name from $FETCH_URL" >&2
        echo "Please check the URL or set the CSV manually with the --csv <name> flag." >&2
        exit 1
    fi
    echo "Successfully fetched latest CSV: $AAP_CSV_NAME"
fi


echo "--- Starting AAP $AAP_VERSION Installation ---"
echo "Using Namespace: $AAP_NAMESPACE"
echo "Using Channel:   $OPERATOR_CHANNEL"
echo "Using CSV:       $AAP_CSV_NAME"
echo "Deploy Flag:     ${DEPLOY_FLAG:-Not Set}"
echo "-----------------------------------------"


wait_for_resource() {
    local command="$1"
    local resource_type="$2"
    local success_condition="$3"
    local result=""

    # Redirect all status messages to stderr (>&2)
    echo "Waiting for $resource_type ($success_condition)..." >&2
    while true; do
        if [[ "$resource_type" == "installplan" ]]; then
            result=$(eval "$command")
            if [[ -n "$result" ]]; then
                echo "Found InstallPlan: $result" >&2
                break
            fi
        elif [[ "$resource_type" == "operator" ]]; then
            PHASE=$(oc get csv "$success_condition" -n "$AAP_NAMESPACE" -o jsonpath="{.status.phase}" 2>/dev/null)
            if [ "$PHASE" == "Succeeded" ]; then
                echo "Operator CSV status is Succeeded." >&2
                break
            else
                echo -n "." >&2 # Progress dot
            fi
        fi
        sleep 5
    done

    # This is the *only* echo that goes to stdout
    echo "$result"
}


echo "Creating project '$AAP_NAMESPACE'..."
oc new-project $AAP_NAMESPACE > /dev/null

echo "Creating OperatorGroup..."
oc create -f - <<EOF
apiVersion: operators.coreos.com/v1
kind: OperatorGroup
metadata:
  generateName: aap-
  namespace: $AAP_NAMESPACE
spec:
  targetNamespaces:
  - $AAP_NAMESPACE
  upgradeStrategy: Default
EOF

echo "Creating Operator Subscription..."
oc apply -f - <<EOF
apiVersion: operators.coreos.com/v1
kind: Operator
metadata:
  name: ansible-automation-platform-operator.$AAP_NAMESPACE
spec: {}
---
apiVersion: operators.coreos.com/v1alpha1
kind: Subscription
metadata:
  labels:
    operators.coreos.com/ansible-automation-platform-operator.$AAP_NAMESPACE: ""
  name: ansible-automation-platform-operator
  namespace: $AAP_NAMESPACE
spec:
  channel: $OPERATOR_CHANNEL
  installPlanApproval: Manual
  name: ansible-automation-platform-operator
  source: redhat-operators
  sourceNamespace: openshift-marketplace
  startingCSV: $AAP_CSV_NAME
EOF

INSTALL_PLAN_COMMAND="oc get installplans -n $AAP_NAMESPACE -l operators.coreos.com/ansible-automation-platform-operator.$AAP_NAMESPACE -o jsonpath='{.items[?(@.spec.approved==false)].metadata.name}'"
INSTALL_PLAN=$(wait_for_resource "$INSTALL_PLAN_COMMAND" "installplan" "Unapproved InstallPlan")

if [[ -z "$INSTALL_PLAN" ]]; then
    echo "Error: Could not find an unapproved InstallPlan." >&2
    exit 1
fi

# Approve the install plan
echo "Approving InstallPlan: $INSTALL_PLAN"
oc patch installplan "$INSTALL_PLAN" \
    --namespace "$AAP_NAMESPACE" \
    --type merge \
    --patch '{"spec":{"approved":true}}'

echo "Waiting for the operator CSV to be installed..."
wait_for_resource "" "operator" "$AAP_CSV_NAME"

echo "Operator is successfully installed."

if [[ "$DEPLOY_FLAG" == "--deploy" ]]; then
    echo "Deploying AAP $AAP_VERSION instance..."

    if [[ "$AAP_VERSION" == "2.5" || "$AAP_VERSION" == "2.6" ]]; then
        # --- AAP 2.5 / 2.6 DEPLOY YAML ---
        oc apply -f - <<EOF
apiVersion: aap.ansible.com/v1alpha1
kind: AnsibleAutomationPlatform
metadata:
  name: example
  namespace: $AAP_NAMESPACE
spec:
  image_pull_policy: IfNotPresent
  controller:
    disabled: false
  eda:
    disabled: true
  hub:
    disabled: true
  lightspeed:
    disabled: true
EOF
    elif [[ "$AAP_VERSION" == "2.4" ]]; then
        # --- AAP 2.4 DEPLOY YAML ---
        oc apply -f - <<EOF
apiVersion: automationcontroller.ansible.com/v1beta1
kind: AutomationController
metadata:
  labels:
    app.kubernetes.io/component: automationcontroller
    app.kubernetes.io/managed-by: automationcontroller-operator
    app.kubernetes.io/operator-version: '2.4'
    app.kubernetes.io/part-of: example
  name: example
  namespace: $AAP_NAMESPACE
spec:
  postgres_keepalives_count: 5
  postgres_keepalives_idle: 5
  metrics_utility_cronjob_report_schedule: '@monthly'
  create_preload_data: true
  route_tls_termination_mechanism: Edge
  garbage_collect_secrets: false
  ingress_type: Route
  loadbalancer_port: 80
  web_replicas: 2
  no_log: true
  image_pull_policy: IfNotPresent
  loadbalancer_ip: ''
  projects_storage_size: 8Gi
  auto_upgrade: true
  task_privileged: false
  postgres_keepalives: true
  metrics_utility_enabled: false
  postgres_keepalives_interval: 5
  ipv6_disabled: false
  task_replicas: 4
  projects_storage_access_mode: ReadWriteMany
  metrics_utility_pvc_claim_size: 5Gi
  set_self_labels: true
  postgres_storage_requirements:
    requests:
      storage: 1Gi
  projects_persistence: false
  replicas: 1
  admin_user: admin
  loadbalancer_protocol: http
  metrics_utility_cronjob_gather_schedule: '@hourly'
EOF
    fi
    echo "AAP $AAP_VERSION instance deployment initiated."
fi

echo "Script finished."
