#!/bin/bash

set -e
set -u
set -o pipefail
set +x
umask 077

if [[ "${KONFLUX_DEPLOY_OPERATORS:-true}" == "false" ]]; then
    echo "Skipping deployment due to KONFLUX_DEPLOY_OPERATORS flag"
    exit 0
fi

WORK_DIR=$(mktemp -d)
trap 'rm -rf "${WORK_DIR}"' EXIT
export TMPDIR="${WORK_DIR}"
export ART_IMAGES_SOURCE="${ART_IMAGES_SOURCE:-registry.stage.redhat.io}"
if [[ ! "${ART_IMAGES_SOURCE}" =~ ^[a-zA-Z0-9.-]+(:[0-9]+)?$ ]]; then
    echo "ERROR: ART_IMAGES_SOURCE must be a registry host, without a scheme or repository"
    exit 1
fi

declare -r TOOLS_DIR=/tmp/bin
declare -r MIRROR_REGISTRY_DIR="${MIRROR_REGISTRY_DIR:-"/var/run/vault/mirror-registry"}"
declare -r MIRROR_REGISTRY_CREDS="${MIRROR_REGISTRY_DIR}/registry_creds"
declare -r CI_USE_REGISTRY_PROXY="${KONFLUX_USE_REGISTRY_PROXY:-false}"
declare -r REGISTRY_PROXY_HOST="${KONFLUX_REGISTRY_PROXY_HOST:-""}"
declare -r REGISTRY_PROXY_PORT="${KONFLUX_REGISTRY_PROXY_PORT:-""}"

if [[ -n "${KONFLUX_TARGET_OPERATORS:-}" && -n "${KONFLUX_TARGET_FBC_TAGS:-}" ]]; then
    echo "ERROR: KONFLUX_TARGET_OPERATORS and KONFLUX_TARGET_FBC_TAGS cannot be set at the same time"
    exit 1
fi

if [[ -n "${REGISTRY_PROXY_HOST:-}" && -z "${REGISTRY_PROXY_PORT:-}" ]]; then
    echo "ERROR: KONFLUX_REGISTRY_PROXY_PORT is required when KONFLUX_REGISTRY_PROXY_HOST is set"
    exit 1
fi

function set_proxy () {
    if test -s "${SHARED_DIR}/proxy-conf.sh" ; then
        echo "setting the proxy"
        # cat "${SHARED_DIR}/proxy-conf.sh"
        echo "source ${SHARED_DIR}/proxy-conf.sh"
        source "${SHARED_DIR}/proxy-conf.sh"
    else
        echo "no proxy setting."
    fi
}

function run_command() {
    local CMD="$1"
    echo "Running Command: ${CMD}"
    eval "${CMD}"
}

function create_registry_auth() {
    local registry_url="$1"
    local auth_creds="$2"
    local auth_file
    auth_file=$(mktemp "${WORK_DIR}/auth.XXXXXX")
    cat <<EOF > "${auth_file}"
{
    "auths": {
        "${registry_url}": {
            "auth": "${auth_creds}"
        }
    }
}
EOF
    echo "${auth_file}"
}

declare -r OPM_IMAGE=quay.io/openshift/origin-operator-registry@sha256:f3986f2395c248aaa36bfb33e44d258841013958106d1efb4c842ba78a3a8e2d

function install_opm() {
    echo "Install opm"
    local scratch err="" out=""
    local auth_args=(-a "${REGISTRY_AUTH_FILE}")
    scratch=$(mktemp -d "${WORK_DIR}/opm.XXXXXX")

    # Keep the extract output in its own variable: on success it is empty, and overwriting
    # ${err} with it would discard the reason the pull-secret could not be read.
    if out=$(oc image extract "${OPM_IMAGE}" --path "/usr/bin/registry/opm:${scratch}" \
                ${auth_args[@]+"${auth_args[@]}"} --confirm 2>&1) &&
       [[ -f "${scratch}/opm" ]] &&
       chmod +x "${scratch}/opm" &&
       "${scratch}/opm" version >/dev/null 2>&1; then
        # Guarded so that a failure here cannot exit under `set -e` and leave the scratch
        # directory, which holds the decoded pull-secret, behind.
        if cp "${scratch}/opm" "${TOOLS_DIR}/opm" && chmod +x "${TOOLS_DIR}/opm"; then
            rm -rf "${scratch}"
            echo "Installed opm from ${OPM_IMAGE}"
            return 0
        fi
        out="could not install the extracted opm into ${TOOLS_DIR}"
    fi

    rm -rf "${scratch}"
    if [[ -n "${out}" ]]; then
        err="${out}"
    fi

    # A missing opm is not fatal when operator deployment is switched off.
    if [[ "${KONFLUX_DEPLOY_OPERATORS:-true}" == "false" ]]; then
        echo "WARNING: could not install opm from ${OPM_IMAGE}; continuing because KONFLUX_DEPLOY_OPERATORS is false and opm is not used"
        if [[ -n "${err}" ]]; then
            echo "WARNING: last error was: ${err}"
        fi
        return 0
    fi

    echo "ERROR: could not install opm from ${OPM_IMAGE}"
    if [[ -n "${err}" ]]; then
        echo "ERROR: last error was: ${err}"
    fi
    exit 1
}

# oc is injected into the step container by ci-operator itself (see the `cli` field of the
# step reference), which mounts the client from the release payload under ${CLI_DIR}.
# ci-operator only appends that directory to PATH, so copying the client into TOOLS_DIR is
# what actually puts it ahead of any older oc baked into the test image.
function install_oc() {
    echo "Install oc"
    run_command "cp ${CLI_DIR:-/cli}/oc ${TOOLS_DIR}/oc && chmod +x ${TOOLS_DIR}/oc"
}

deploy_operator_main() (
set -Eeuo pipefail
trap - EXIT

# See --operator flag for valid operators
VALID_OPERATORS="sriov metallb nmstate ptp pfstatus local-storage"

KONFLUX_DEPLOY_OPERATORS="${KONFLUX_DEPLOY_OPERATORS:-true}"
# Env variables to control the deployment of CatalogSource and Subscription
KONFLUX_DEPLOY_CATALOG_SOURCE="${KONFLUX_DEPLOY_CATALOG_SOURCE:-true}"
KONFLUX_DEPLOY_SUBSCRIPTION="${KONFLUX_DEPLOY_SUBSCRIPTION:-true}"

# Color codes for logging
CYAN='\033[0;36m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
RED='\033[0;31m'
NC='\033[0m' # No Color

# Logging functions
log_step() {
    echo ""
    echo "============================================================"
    echo "$1"
    echo "============================================================"
}


log() {
    local level="$1"
    local msg="$2"
    case "$level" in
        "INFO")    echo -e "${CYAN}[INFO]${NC} $msg" ;;
        "SUCCESS") echo -e "${GREEN}[SUCCESS]${NC} $msg" ;;
        "ERROR")   echo -e "${RED}[ERROR]${NC} $msg" >&2 ;;
        "WARNING") echo -e "${YELLOW}[WARNING]${NC} $msg" ;;
        *)         echo "[$level] $msg" ;;
    esac
}

display_metadata() {
    echo ""
    echo "============================================================"
    echo -e "${YELLOW}              EXTRACTED OPERATOR METADATA FROM FBC${NC}"
    echo "============================================================"

    # Read all input into an array
    local lines=()
    while IFS= read -r line; do
        lines+=("$line")
    done

    # Find the empty line separator
    local separator_index=-1
    for i in "${!lines[@]}"; do
        if [[ -z "${lines[i]}" ]]; then
            separator_index=$i
            break
        fi
    done

    # Print basic metadata (before empty line)
    for ((i=0; i<separator_index; i++)); do
        if [[ -n "${lines[i]}" ]]; then
            echo -e "${YELLOW}${lines[i]}${NC}"
        fi
    done

    # Print related images with label but no extra separators
    echo -e "${YELLOW}Related Images:${NC}"
    for ((i=separator_index+1; i<${#lines[@]}; i++)); do
        if [[ -n "${lines[i]}" ]]; then
            echo -e "${YELLOW}${lines[i]}${NC}"
        fi
    done
    echo "============================================================"
}

if [[ "$KONFLUX_DEPLOY_OPERATORS" == false ]]; then
    log "INFO" "Skipping deployment due to KONFLUX_DEPLOY_OPERATORS flag"
    exit 0
fi

# Parse arguments
log_step "INIT" "Starting Konflux Operator Deployment"
log "INFO" "Using MCP timeout: ${MCP_TIMEOUT:-600s}"

log "INFO" "Parsing command line arguments"

# Set default timeout
MCP_TIMEOUT="${MCP_TIMEOUT:-600s}"

while [[ $# -gt 0 ]]; do
    case $1 in
        --operator)
            # This argument is checked against the VALID_OPERATORS list
            OPERATOR="$2"
            log "INFO" "Operator specified: $2"
            shift 2
            ;;
        --fbc-tag)
            FBC_TAG_INPUT="$2"
            log "INFO" "FBC tag specified: $2"
            shift 2
            ;;
        --internal-registry)
            INTERNAL_REGISTRY="$2"
            log "INFO" "Internal registry specified: $2"
            shift 2
            ;;
        --internal-registry-auth)
            INTERNAL_REGISTRY_AUTH="$2"
            log "INFO" "Internal registry auth file specified: $2"
            shift 2
            ;;
        --internal-registry-proxy)
            INTERNAL_REGISTRY_PROXY="$2"
            log "INFO" "Internal registry proxy specified: $2"
            shift 2
            ;;
        --internal-registry-proxy-auth)
            INTERNAL_REGISTRY_PROXY_AUTH="$2"
            log "INFO" "Internal registry proxy auth file specified: $2"
            shift 2
            ;;
        --mcp-timeout)
            MCP_TIMEOUT="$2"
            log "INFO" "MCP timeout set to: $2"
            shift 2
            ;;
        *)
            log "ERROR" "Unknown argument: $1"
            exit 1
            ;;
    esac
done

log "INFO" "Validating operator configuration"



if [[ -n "${OPERATOR:-}" && -n "${FBC_TAG_INPUT:-}" ]]; then
    log "ERROR" "Provide either --operator or --fbc-tag, not both"
    exit 1
fi

if [[ -z "${OPERATOR:-}" && -z "${FBC_TAG_INPUT:-}" ]]; then
    log "ERROR" "Provide either --operator or --fbc-tag"
    exit 1
fi

# Parse comma-separated operators if provided
if [[ -n "${OPERATOR:-}" ]]; then
    IFS=',' read -ra OPERATORS <<< "$OPERATOR"
    log "INFO" "Parsing operators: ${OPERATORS[*]}"

    # Validate all operators are in predefined list
    for op in "${OPERATORS[@]}"; do
        if [[ " $VALID_OPERATORS " != *" $op "* ]]; then
            log "ERROR" "Invalid operator: $op"
            log "ERROR" "Valid operators: $VALID_OPERATORS"
            exit 1
        fi
    done
    log "SUCCESS" "Operators to deploy: ${OPERATORS[*]}"
else
    # FBC tag mode: parse comma-separated FBC tags and use them directly
    IFS=',' read -ra FBC_TAGS <<< "$FBC_TAG_INPUT"
    log "INFO" "Parsed FBC tags: ${FBC_TAGS[*]}"
    OPERATORS=()
    log "INFO" "No operators specified, will use FBC tag mode"
fi

log_step "CONFIG" "Determining cluster mode and validating requirements"

if [[ -n "${INTERNAL_REGISTRY:-}" && -z "${INTERNAL_REGISTRY_AUTH:-}" ]] || [[ -z "${INTERNAL_REGISTRY:-}" && -n "${INTERNAL_REGISTRY_AUTH:-}" ]]; then
    log "ERROR" "Both --internal-registry and --internal-registry-auth must be provided together"
    exit 1
fi

if [[ -n "${INTERNAL_REGISTRY_PROXY:-}" && -z "${INTERNAL_REGISTRY_PROXY_AUTH:-}" ]] || [[ -z "${INTERNAL_REGISTRY_PROXY:-}" && -n "${INTERNAL_REGISTRY_PROXY_AUTH:-}" ]]; then
    log "ERROR" "Both --internal-registry-proxy and --internal-registry-proxy-auth must be provided together"
    exit 1
fi

if [[ -n "${INTERNAL_REGISTRY:-}" && -n "${INTERNAL_REGISTRY_PROXY:-}" ]]; then
    log "ERROR" "Both --internal-registry and --internal-registry-proxy cannot be provided together"
    exit 1
fi

if [[ -n "${INTERNAL_REGISTRY:-}" || -n "${INTERNAL_REGISTRY_PROXY:-}" ]]; then
    DISCONNECTED=true
    log "INFO" "Operating in disconnected cluster mode as either --internal-registry or --internal-registry-proxy is provided"
else
    DISCONNECTED=false
    log "INFO" "Operating in connected cluster mode"
fi

# Determine if we should use proxy registry (default: false - use mirroring)
USE_REGISTRY_PROXY=false

if [[ -n "${INTERNAL_REGISTRY_PROXY:-}" ]]; then
    USE_REGISTRY_PROXY=true
    log "INFO" "Using proxy registry - images will not be mirrored"
fi
log "INFO" "Checking required tools"

# Check core tools (always required)
for cmd in oc opm jq; do
    log "INFO" "Checking for $cmd..."
    command -v "$cmd" >/dev/null 2>&1 || { log "ERROR" "$cmd not installed"; exit 1; }
done

log "SUCCESS" "All required tools are available"

log "INFO" "Validating authentication files"

if [[ -n "${INTERNAL_REGISTRY_AUTH:-}" ]]; then
    log "INFO" "Validating internal registry auth file: $INTERNAL_REGISTRY_AUTH"
    [[ ! -f "$INTERNAL_REGISTRY_AUTH" ]] && { log "ERROR" "Internal registry auth file not found"; exit 1; }
    jq empty "$INTERNAL_REGISTRY_AUTH" 2>/dev/null || { log "ERROR" "Invalid JSON in internal auth"; exit 1; }
    log "SUCCESS" "Internal registry auth file is valid"
fi

if [[ -n "${INTERNAL_REGISTRY_PROXY_AUTH:-}" ]]; then
    log "INFO" "Validating internal registry proxy auth file: $INTERNAL_REGISTRY_PROXY_AUTH"
    [[ ! -f "$INTERNAL_REGISTRY_PROXY_AUTH" ]] && { log "ERROR" "Internal registry proxy auth file not found"; exit 1; }
    jq empty "$INTERNAL_REGISTRY_PROXY_AUTH" 2>/dev/null || { log "ERROR" "Invalid JSON in internal registry proxy auth"; exit 1; }
    log "SUCCESS" "Internal registry proxy auth file is valid"
fi

log "INFO" "Checking cluster connectivity"
log "INFO" "Attempting to connect to OpenShift cluster..."
oc cluster-info &> /dev/null || { log "ERROR" "Cannot connect to cluster"; exit 1; }
log "SUCCESS" "Successfully connected to cluster"

# Detect cluster version
log "INFO" "Detecting OpenShift version..."
VERSION=$(oc get clusterversion version -o jsonpath='{.status.desired.version}' 2>/dev/null | cut -d. -f1-2)
[[ -z "$VERSION" ]] && { log "ERROR" "Could not detect cluster version"; exit 1; }
log "SUCCESS" "Detected OpenShift version: $VERSION"

# Helper function to update cluster pull-secret with auth credentials
# Helper function to get FBC tag for operator
get_fbc_tag() {
    local op=$1
    local ver=$2
    case "$op" in
        sriov) echo "ocp__${ver}__ose-sriov-network-rhel9-operator" ;;
        metallb) echo "ocp__${ver}__metallb-rhel9-operator" ;;
        nmstate) echo "ocp__${ver}__kubernetes-nmstate-rhel9-operator" ;;
        ptp) echo "ocp__${ver}__ose-ptp-rhel9-operator" ;;
        pfstatus) echo "ocp__${ver}__pf-status-relay-rhel9-operator" ;;
        local-storage) echo "ocp__${ver}__ose-local-storage-rhel9-operator" ;;
        *) echo "" ;;
    esac
}

# Helper function to set FBC target
set_fbc_target() {
    local operator_name=$1
    local fbc_tag=$2

    OPERATOR_FBC_SOURCES[$operator_name]="${ART_FBC_BASE}:${fbc_tag}"
    OPERATOR_FBC_TARGETS[$operator_name]="${OPERATOR_FBC_SOURCES[$operator_name]}"

    if [[ "$DISCONNECTED" == true ]]; then
        local registry_target="${INTERNAL_REGISTRY:-}"
        if [[ "$USE_REGISTRY_PROXY" == true ]]; then
            registry_target="${KONFLUX_CATALOG_REGISTRY_PROXY}"
        fi
        OPERATOR_FBC_TARGETS[$operator_name]="${registry_target}/redhat-user-workloads/ocp-art-tenant/art-fbc:${fbc_tag}"
    fi
}

# Helper function to deploy CatalogSource
deploy_catalog_source() {
    local catalog_name=$1
    local fbc_target=$2
    local op=$3

    echo "------------------------------------------------------------"
    echo "Deploying CatalogSource for $op..."
    echo "------------------------------------------------------------"

    log "INFO" "Cleaning up existing CatalogSource for $op..."
    log "INFO" "  - Deleting CatalogSource: $catalog_name"
    oc delete catalogsource "$catalog_name" -n openshift-marketplace --ignore-not-found &>/dev/null || true
    log "SUCCESS" "CatalogSource cleaned up"

    # Create CatalogSource
    log "INFO" "Creating CatalogSource for $op..."
    if ! oc apply -f - <<EOF
apiVersion: operators.coreos.com/v1alpha1
kind: CatalogSource
metadata:
  name: ${catalog_name}
  namespace: openshift-marketplace
spec:
  displayName: ${catalog_name}
  image: ${fbc_target}
  sourceType: grpc
EOF
    then
        log "ERROR" "CatalogSource apply failed for $op"
        return 1
    else
        log "SUCCESS" "CatalogSource created"
    fi

    # Wait for catalog ready
    log "INFO" "Waiting for CatalogSource to be ready..."
    if ! oc wait --for=jsonpath='{.status.connectionState.lastObservedState}'=READY \
        catalogsource "$catalog_name" -n openshift-marketplace --timeout=300s 2>/dev/null; then
        log "ERROR" "CatalogSource $catalog_name not ready within timeout"
        return 1
    else
        log "SUCCESS" "CatalogSource is ready"
    fi

    return 0
}

# Helper function to deploy operator
deploy_operator() {
    local op=$1
    local operator_name=$2
    local operator_namespace=$3
    local latest_bundle=$4
    local default_channel=$5
    local install_mode=$6
    local catalog_name=$7

    echo "------------------------------------------------------------"
    echo "Deploying Operator for $op..."
    echo "------------------------------------------------------------"

    log "INFO" "Cleaning up existing namespace for $op..."
    log "INFO" "  - Deleting namespace: $operator_namespace"
    oc delete namespace "$operator_namespace" --ignore-not-found &>/dev/null || true
    log "SUCCESS" "Namespace cleaned up"

    # Create namespace
    log "INFO" "Creating Namespace for $op..."
    if ! oc apply -f - >/dev/null 2>&1 <<EOF
apiVersion: v1
kind: Namespace
metadata:
  name: $operator_namespace
  labels:
    pod-security.kubernetes.io/enforce: privileged
EOF
    then
        log "ERROR" "Namespace creation failed for $op"
        return 1
    fi
    log "SUCCESS" "Namespace created"

    # Create OperatorGroup
    log "INFO" "Creating OperatorGroup for $op..."
    if [[ "$install_mode" == "AllNamespaces" ]]; then
        if ! oc apply -f - <<EOF
apiVersion: operators.coreos.com/v1
kind: OperatorGroup
metadata:
  name: operator-group-${operator_name}
  namespace: ${operator_namespace}
spec: {}
EOF
        then
            log "ERROR" "OperatorGroup apply failed for $op"
            return 1
        fi
    else
        if ! oc apply -f - <<EOF
apiVersion: operators.coreos.com/v1
kind: OperatorGroup
metadata:
  name: operator-group-${operator_name}
  namespace: ${operator_namespace}
spec:
  targetNamespaces:
  - ${operator_namespace}
EOF
        then
            log "ERROR" "OperatorGroup apply failed for $op"
            return 1
        fi
    fi
    log "SUCCESS" "OperatorGroup created"

    # Create Subscription
    log "INFO" "Creating Subscription for $op..."
    if ! oc apply -f - <<EOF
apiVersion: operators.coreos.com/v1alpha1
kind: Subscription
metadata:
  name: ${operator_name}
  namespace: ${operator_namespace}
spec:
  channel: $default_channel
  installPlanApproval: Automatic
  name: ${operator_name}
  source: $catalog_name
  sourceNamespace: openshift-marketplace
EOF
    then
        log "ERROR" "Subscription apply failed for $op"
        return 1
    fi
    log "SUCCESS" "Subscription created"

    # Wait for subscription to get currentCSV
    log "INFO" "Waiting for subscription to resolve..."
    if ! oc wait --for=jsonpath='{.status.currentCSV}'="${latest_bundle}" subscription "${operator_name}" -n "${operator_namespace}" --timeout=120s 2>/dev/null; then
        log "ERROR" "Subscription did not resolve within timeout"
        return 1
    fi
    log "SUCCESS" "Subscription resolved"

    # Wait for CSV
    log "INFO" "Waiting for CSV ${latest_bundle} to be created..."
    csv_timeout=180
    csv_elapsed=0
    csv_created=false
    while [[ $csv_elapsed -lt $csv_timeout ]]; do
        if oc get csv "$latest_bundle" -n "$operator_namespace" >/dev/null 2>&1; then
            csv_created=true
            break
        fi
        sleep 2
        csv_elapsed=$((csv_elapsed + 2))
    done
    if [[ "$csv_created" == false ]]; then
        log "ERROR" "CSV ${latest_bundle} not created within timeout"
        return 1
    fi
    log "SUCCESS" "CSV created"

    log "INFO" "Waiting for CSV ${latest_bundle} to reach Succeeded phase..."
    if ! oc wait --for=jsonpath='{.status.phase}'=Succeeded csv "$latest_bundle" -n "$operator_namespace" --timeout=120s 2>/dev/null; then
        log "ERROR" "CSV ${latest_bundle} did not reach Succeeded phase"
        return 1
    fi
    log "SUCCESS" "CSV reached Succeeded phase"

    # Wait for operator pods
    log "INFO" "Waiting for operator pods to be ready..."
    if ! oc wait --for=condition=Ready pods --all -n "$operator_namespace" --timeout=120s 2>/dev/null; then
        log "ERROR" "Operator pods not ready within timeout"
        return 1
    fi
    log "SUCCESS" "All operator pods are ready"

    return 0
}

# Set operator config
ART_IMAGES_SOURCE="${ART_IMAGES_SOURCE:-registry.stage.redhat.io}"
ART_FBC_BASE="quay.io/redhat-user-workloads/ocp-art-tenant/art-fbc"

# Arrays to store operator metadata
declare -A OPERATOR_CATALOG_NAMES
declare -A OPERATOR_FBC_SOURCES
declare -A OPERATOR_FBC_TARGETS
declare -A OPERATOR_NAMES
declare -A OPERATOR_BUNDLES
declare -A OPERATOR_NAMESPACES
declare -A OPERATOR_CHANNELS
declare -A OPERATOR_INSTALL_MODES

# Unified deployment configuration
# DEPLOYMENT_KEYS array will contain either operator names or FBC tags
declare -a DEPLOYMENT_KEYS=()

if [[ ${#OPERATORS[@]} -gt 0 ]]; then
    # Operator mode: derive FBC tags from operator names
    for op in "${OPERATORS[@]}"; do
        fbc_tag=$(get_fbc_tag "$op" "$VERSION")
        DEPLOYMENT_KEYS+=("$op")
        OPERATOR_CATALOG_NAMES[$op]="${op}-konflux"
        set_fbc_target "$op" "$fbc_tag"
    done
else
    # FBC tag mode: use provided FBC tags directly
    for fbc_tag in "${FBC_TAGS[@]}"; do
        DEPLOYMENT_KEYS+=("$fbc_tag")
        # Create a sanitized catalog name from the FBC tag
        catalog_name=$(echo "$fbc_tag" | tr ':' '-' | tr '/' '-' | tr '_' '-')
        OPERATOR_CATALOG_NAMES[$fbc_tag]="${catalog_name}-konflux"
        set_fbc_target "$fbc_tag" "$fbc_tag"
    done
fi

# Mirror FBC images and extract metadata
log_step "METADATA" "Extracting operator metadata from FBC"

log "INFO" "Processing ${#DEPLOYMENT_KEYS[@]} operator(s)/FBC tag(s)"

# Temporary file to collect all related images across all operators
ALL_IMAGES_FILE=$(mktemp)

for op in "${DEPLOYMENT_KEYS[@]}"; do
    log "INFO" "Processing operator: $op"

    fbc_source="${OPERATOR_FBC_SOURCES[$op]}"
    fbc_target="${OPERATOR_FBC_TARGETS[$op]}"

    # Mirror FBC image if disconnected and not using proxy
    if [[ "$DISCONNECTED" == true && "$USE_REGISTRY_PROXY" == false ]]; then
        echo "Mirroring FBC image..."
        if mirror_output=$(oc image mirror --keep-manifest-list=true -a "$REGISTRY_AUTH_FILE" "$fbc_source" "$fbc_target" 2>&1); then
            mirror_status=0
        else
            mirror_status=$?
        fi
        if [[ $mirror_status -ne 0 ]]; then
            echo "ERROR: Failed to mirror FBC for $op" >&2
            echo "Source: $fbc_source" >&2
            echo "Target: $fbc_target" >&2
            echo "Error output:" >&2
            echo "$mirror_output" >&2
            exit 1
        fi
    fi

    # Extract metadata from FBC
    log "INFO" "Rendering FBC: $fbc_source"
    opm_output=$(opm render "$fbc_source") || { log "ERROR" "opm render failed for $op"; exit 1; }

    log "INFO" "Finding latest bundle version..."
    latest_bundle=$(echo "$opm_output" | jq -r 'select(.schema == "olm.bundle") | .name' | sort -V | tail -1)
    [[ -z "$latest_bundle" ]] && { log "ERROR" "No bundle found for $op"; exit 1; }

    log "INFO" "Extracting bundle data..."
    bundle_data=$(echo "$opm_output" | jq "select(.schema == \"olm.bundle\" and .name == \"$latest_bundle\")")

    log "INFO" "Extracting operator metadata..."
    operator_name=$(echo "$bundle_data" | jq -r '.package // empty' | head -1)
    [[ -z "$operator_name" ]] && { log "ERROR" "Could not extract operator name for $op"; exit 1; }

    operator_namespace=$(echo "$bundle_data" | jq -r '.properties[]? | select(.type == "olm.csv.metadata") | .value.annotations["operatorframework.io/suggested-namespace"] // empty' | head -1)
    if [[ -z "$operator_namespace" ]]; then
        operator_namespace="openshift-${operator_name}"
        namespace_source="derived"
    else
        namespace_source="annotated"
    fi

    default_channel=$(echo "$opm_output" | jq -r 'select(.schema == "olm.package") | .defaultChannel // "stable"' | head -1)
    [[ -z "$default_channel" ]] && default_channel="stable"

    install_mode=$(echo "$bundle_data" | jq -r '.properties[]? | select(.type == "olm.csv.metadata") | .value.installModes[]? | select(.supported == true) | .type' | head -1)
    [[ -z "$install_mode" ]] && install_mode="SingleNamespace"

    # Store metadata
    OPERATOR_NAMES[$op]="$operator_name"
    OPERATOR_BUNDLES[$op]="$latest_bundle"
    OPERATOR_NAMESPACES[$op]="$operator_namespace"
    OPERATOR_CHANNELS[$op]="$default_channel"
    OPERATOR_INSTALL_MODES[$op]="$install_mode"

    # Print metadata using display_metadata function
    {
        echo "Operator Name:    $operator_name"
        echo "Bundle Name:      $latest_bundle"
        echo "Namespace:        $operator_namespace ($namespace_source)"
        echo "Channel:          $default_channel"
        echo "Install Mode:     $install_mode"
        echo ""
        echo "$bundle_data" | jq -r '.relatedImages[]?.image // empty' | grep -v '^$' | sort -u | nl -w2 -s'. '
    } | display_metadata

    # Collect related images to temp file
    echo "$bundle_data" | jq -r '.relatedImages[]?.image // empty' 2>/dev/null | grep -v '^$' >> "$ALL_IMAGES_FILE"
done

# Calculate total unique images
total_images=$(sort -u "$ALL_IMAGES_FILE" | wc -l)

echo ""
echo "============================================================"
echo "Total unique images across all operators: $total_images"
echo "============================================================"

# Mirror all related images if disconnected and not using proxy
if [[ "$DISCONNECTED" == true && "$USE_REGISTRY_PROXY" == false ]]; then
    MERGED_AUTH_FILE=$(mktemp)
    cp "$REGISTRY_AUTH_FILE" "$MERGED_AUTH_FILE"

    # Sort unique images to a new file (avoids pipefail issues with process substitution)
    SORTED_IMAGES_FILE=$(mktemp)
    sort -u "$ALL_IMAGES_FILE" > "$SORTED_IMAGES_FILE"
    rm -f "$ALL_IMAGES_FILE"

    echo "Mirroring related images..."
    image_count=0

    # Read directly from the sorted file
    set +e  # Temporarily disable exit on error for the loop
    while IFS= read -r image; do
        [[ -z "$image" ]] && continue

        digest=$(echo "$image" | grep -o 'sha256:[a-f0-9]\{64\}')
        [[ -z "$digest" ]] && continue

        ((image_count++))
        echo "  [$image_count/$total_images] Mirroring $digest..."
        source="$image"
        repository="${image%@*}"
        if [[ "$image" == registry.redhat.io/* ]]; then
            source="${ART_IMAGES_SOURCE}/${image#registry.redhat.io/}"
            repository="${repository#registry.redhat.io/}"
        fi
        target="${INTERNAL_REGISTRY}/${repository}@${digest}"

        mirror_output=$(oc image mirror --keep-manifest-list=true -a "$MERGED_AUTH_FILE" "$source" "$target" </dev/null 2>&1)
        mirror_status=$?
        if [[ $mirror_status -eq 0 ]]; then
            echo "    ✓ Success"
        else
            set -e  # Re-enable exit on error
            echo "ERROR: Failed to mirror $digest" >&2
            echo "Source: $source" >&2
            echo "Target: $target" >&2
            echo "Digest: $digest" >&2
            echo "Error output:" >&2
            echo "$mirror_output" >&2
            rm -f "$MERGED_AUTH_FILE" "$SORTED_IMAGES_FILE"
            exit 1
        fi
    done < "$SORTED_IMAGES_FILE"
    set -e  # Re-enable exit on error

    echo "Successfully mirrored all $image_count images"
    rm -f "$MERGED_AUTH_FILE" "$SORTED_IMAGES_FILE"
else
    rm -f "$ALL_IMAGES_FILE"
fi

# Create IDMS
log_step "IDMS" "Creating Image Digest Mirror Sets (IDMS)"

# Create separate IDMS for each deployment key
log "INFO" "Generating IDMS for each operator/FBC tag"

if [[ "$DISCONNECTED" == true ]]; then
    mirror_registry="${INTERNAL_REGISTRY:-}"
    if [[ "$USE_REGISTRY_PROXY" == true ]]; then
        mirror_registry="${INTERNAL_REGISTRY_PROXY}"
    fi
    IDMS_MIRROR="${mirror_registry}"
    IDMS_SUFFIX="internal-idms"
else
    IDMS_MIRROR="${ART_IMAGES_SOURCE}"
    IDMS_SUFFIX="art-idms"
fi

# Store IDMS YAMLs in temp files
declare -A OPERATOR_IDMS_FILES

# Loop 1: Generate all IDMS YAMLs
for op in "${DEPLOYMENT_KEYS[@]}"; do
    fbc_source="${OPERATOR_FBC_SOURCES[$op]}"
    # Sanitize the deployment key for use in IDMS name
    sanitized_key=$(echo "$op" | tr ':' '-' | tr '/' '-' | tr '_' '-')
    idms_name="${sanitized_key}-${IDMS_SUFFIX}"

    echo "  Generating IDMS: $idms_name"

    # Re-render FBC to get bundle data for this operator
    opm_output=$(opm render "$fbc_source" 2>/dev/null) || { echo "ERROR: opm render failed for $op" >&2; exit 1; }
    latest_bundle=$(echo "$opm_output" | jq -r 'select(.schema == "olm.bundle") | .name' | sort -V | tail -1)
    bundle_data=$(echo "$opm_output" | jq "select(.schema == \"olm.bundle\" and .name == \"$latest_bundle\")")

    # Create temp file for this IDMS
    idms_file=$(mktemp)
    OPERATOR_IDMS_FILES[$op]="$idms_file"

    {
        echo "apiVersion: config.openshift.io/v1
kind: ImageDigestMirrorSet
metadata:
  name: ${idms_name}
spec:
  imageDigestMirrors:"
        if [[ "$DISCONNECTED" == false || "$USE_REGISTRY_PROXY" == true ]]; then
            echo "  - mirrors:
    - ${IDMS_MIRROR}
    source: registry.redhat.io"
        else
            while IFS= read -r repo; do
                [[ -z "$repo" ]] && continue
                mirror_path="$repo"
                if [[ "$repo" == registry.redhat.io/* ]]; then
                    mirror_path="${repo#registry.redhat.io/}"
                fi
                echo "  - mirrors:
    - ${IDMS_MIRROR}/${mirror_path}
    source: $repo"
            done < <(echo "$bundle_data" | jq -r '.relatedImages[]?.image // empty' | sed 's/@.*$//' | sort -u)
        fi
    } > "$idms_file"
done

# Loop 2: Apply all IDMS YAMLs to cluster
echo ""
echo "Applying all IDMS to cluster..."
for op in "${DEPLOYMENT_KEYS[@]}"; do
    idms_file="${OPERATOR_IDMS_FILES[$op]}"
    # Sanitize the deployment key for use in IDMS name
    sanitized_key=$(echo "$op" | tr ':' '-' | tr '/' '-' | tr '_' '-')
    idms_name="${sanitized_key}-${IDMS_SUFFIX}"
    echo "  Applying IDMS: $idms_name"
    oc apply -f "$idms_file" || { echo "ERROR: IDMS apply failed for $op" >&2; exit 1; }
    rm -f "$idms_file"
done

log "INFO" "Waiting for Machine Config Pool update after IDMS creation..."
oc wait --for=condition=Updating mcp --all --timeout=60s >/dev/null 2>&1 || true
oc wait --for=condition=Updating=false mcp --all --timeout=${MCP_TIMEOUT} >/dev/null 2>&1 || true
log "SUCCESS" "Machine Config Pool update completed"

# Add insecure registry
log "INFO" "Configuring cluster settings"

if [[ "$DISCONNECTED" == true ]]; then
    log "INFO" "Adding insecure registry configuration..."
    # Use proxy registry if provided, otherwise use internal registry
    registry_to_configure="${INTERNAL_REGISTRY:-}"
    if [[ "$USE_REGISTRY_PROXY" == true ]]; then
        registry_to_configure="${INTERNAL_REGISTRY_PROXY}"
    fi
    oc patch image.config.openshift.io/cluster --patch '{"spec":{ "registrySources": { "insecureRegistries" : ["'"${registry_to_configure}"'"] }}}' --type=merge || \
        { log "ERROR" "Failed to patch image config"; exit 1; }

    log "INFO" "Waiting for Machine Config Pool update after registry config..."
    oc wait --for=condition=Updating mcp --all --timeout=60s >/dev/null 2>&1 || true
    oc wait --for=condition=Updating=false mcp --all --timeout=${MCP_TIMEOUT} >/dev/null 2>&1 || true
    log "SUCCESS" "Machine Config Pool update completed"
fi

# Disable default catalogs
DEFAULT_CATALOGS_DISABLED=false
restore_default_catalogs() {
    if [[ "$DEFAULT_CATALOGS_DISABLED" != true ]]; then
        return 0
    fi
    log "INFO" "Restoring default catalogs..."
    if oc patch operatorhub cluster -p '{"spec": {"disableAllDefaultSources": false}}' --type=merge; then
        log "SUCCESS" "Default catalogs restored"
        DEFAULT_CATALOGS_DISABLED=false
    else
        log "WARNING" "Failed to restore default catalogs"
    fi
}
trap restore_default_catalogs EXIT

log "INFO" "Disabling default catalogs..."
oc patch operatorhub cluster -p '{"spec": {"disableAllDefaultSources": true}}' --type=merge || \
    { log "ERROR" "Failed to disable default catalogs"; exit 1; }
DEFAULT_CATALOGS_DISABLED=true
log "SUCCESS" "Default catalogs disabled"

# Deploy operators
log_step "DEPLOY" "Starting Operator Deployment"

# Deploy all operators/FBC tags
log "INFO" "Deploying ${#DEPLOYMENT_KEYS[@]} operator(s)/FBC tag(s)"

# Arrays to track deployment status
declare -a FAILED_OPERATORS=()
declare -a SUCCESS_OPERATORS=()

for op in "${DEPLOYMENT_KEYS[@]}"; do

    catalog_name="${OPERATOR_CATALOG_NAMES[$op]}"
    fbc_target="${OPERATOR_FBC_TARGETS[$op]}"
    operator_name="${OPERATOR_NAMES[$op]}"
    operator_namespace="${OPERATOR_NAMESPACES[$op]}"
    latest_bundle="${OPERATOR_BUNDLES[$op]}"
    default_channel="${OPERATOR_CHANNELS[$op]}"
    install_mode="${OPERATOR_INSTALL_MODES[$op]}"

    # Flag to track if this operator deployment failed
    deployment_failed=false

    # Temporarily disable exit on error for this operator's deployment
    set +e

    if [[ "$KONFLUX_DEPLOY_CATALOG_SOURCE" == true ]]; then
        # Deploy CatalogSource
        if ! deploy_catalog_source "$catalog_name" "$fbc_target" "$op"; then
            deployment_failed=true
        fi
    fi

    if [[ "$KONFLUX_DEPLOY_SUBSCRIPTION" == true && "$deployment_failed" == false ]]; then
        # Deploy Operator
        if ! deploy_operator "$op" "$operator_name" "$operator_namespace" "$latest_bundle" "$default_channel" "$install_mode" "$catalog_name"; then
            deployment_failed=true
        fi
    fi

    # Re-enable exit on error
    set -e

        # Record result
    if [[ "$deployment_failed" == true ]]; then
        FAILED_OPERATORS+=("$op")
        log "ERROR" "Operator $op deployment failed, continuing with next operator..."
    else
        SUCCESS_OPERATORS+=("$op")
        log "SUCCESS" "Operator $op deployed successfully"
    fi
done

log_step "SUMMARY" "Deployment Summary"

if [[ ${#SUCCESS_OPERATORS[@]} -gt 0 ]]; then
    log "SUCCESS" "Successfully deployed (${#SUCCESS_OPERATORS[@]}): ${SUCCESS_OPERATORS[*]}"
fi

if [[ ${#FAILED_OPERATORS[@]} -gt 0 ]]; then
    log "ERROR" "Failed to deploy (${#FAILED_OPERATORS[@]}): ${FAILED_OPERATORS[*]}"
    log "ERROR" "Deployment completed with errors!"
    exit 1
else
    log "SUCCESS" "All operators deployed successfully!"
fi

)

function deploy_operators() {
    cd "${WORK_DIR}"

    declare args=()
    if [[ -n "${KONFLUX_TARGET_OPERATORS:-}" ]]; then
        args+=(--operator "${KONFLUX_TARGET_OPERATORS}")
    fi
    if [[ -n "${KONFLUX_TARGET_FBC_TAGS:-}" ]]; then
        args+=(--fbc-tag "${KONFLUX_TARGET_FBC_TAGS}")
    fi


    if [[ "${DISCONNECTED:-false}" == "true" ]]; then
        local mirror_registry_creds
        mirror_registry_creds=$(head -n 1 "${MIRROR_REGISTRY_CREDS}" | base64 -w 0)
        local mirror_registry_url
        mirror_registry_url=$(head -n 1 "${SHARED_DIR}/mirror_registry_url")

        # Configure registry proxy if enabled
        if [[ "${CI_USE_REGISTRY_PROXY:-false}" == "true" ]]; then
            local registry_proxy_url="${ART_REGISTRY_PROXY}"

            local registry_proxy_auth
            registry_proxy_auth=$(create_registry_auth "${registry_proxy_url}" "${mirror_registry_creds}")
            args+=(--internal-registry-proxy "${registry_proxy_url}" --internal-registry-proxy-auth "${registry_proxy_auth}")
        else
            local registry_auth
            registry_auth=$(create_registry_auth "${mirror_registry_url}" "${mirror_registry_creds}")
            args+=(--internal-registry "${mirror_registry_url}" --internal-registry-auth "${registry_auth}")
        fi
    fi

    deploy_operator_main "${args[@]}"
}

# Merge registry auth and roll out only when canonical pull-secret content changes.
function prepare_registry_auth() {
    local stage_credentials="${MIRROR_REGISTRY_DIR}/registry_stage.json"
    if [[ ! -s "${stage_credentials}" ]] || ! jq -e '
        (.user | type == "string" and length > 0) and
        (.password | type == "string" and length > 0)
    ' "${stage_credentials}" >/dev/null 2>&1; then
        echo "ERROR: required stage credentials must contain nonempty user and password: ${stage_credentials}"
        return 1
    fi

    export DOCKER_CONFIG="${WORK_DIR}/docker"
    mkdir -p "${DOCKER_CONFIG}"
    export REGISTRY_AUTH_FILE="${DOCKER_CONFIG}/config.json"
    oc extract secret/pull-secret -n openshift-config --confirm --to "${WORK_DIR}" >/dev/null
    jq --arg registry "${ART_IMAGES_SOURCE}" --slurpfile stage "${stage_credentials}" '
        .auths[$registry] = {auth: (($stage[0].user + ":" + $stage[0].password) | @base64)}
    ' "${WORK_DIR}/.dockerconfigjson" > "${REGISTRY_AUTH_FILE}"

    if [[ "${DISCONNECTED:-false}" == "true" ]]; then
        local registry_url registry_auth proxy_url proxy_port
        registry_url=$(head -n 1 "${SHARED_DIR}/mirror_registry_url")
        if [[ "${CI_USE_REGISTRY_PROXY}" == "true" ]]; then
            proxy_port="${REGISTRY_PROXY_PORT:-6003}"
            if [[ "${proxy_port}" == "6004" ]]; then
                proxy_port=6003
            fi
            proxy_url="${REGISTRY_PROXY_HOST:-${registry_url%:*}}:${proxy_port}"
            export ART_REGISTRY_PROXY="${proxy_url}"
            export KONFLUX_CATALOG_REGISTRY_PROXY="${KONFLUX_CATALOG_REGISTRY_PROXY:-${proxy_url%:*}:6001}"
            registry_url="${proxy_url}"
        fi
        registry_auth=$(head -n 1 "${MIRROR_REGISTRY_CREDS}" | base64 -w 0)
        create_registry_auth "${registry_url}" "${registry_auth}" > "${WORK_DIR}/auth-path"
        jq -s '.[0] * {auths: (.[0].auths + .[1].auths)}' \
            "${REGISTRY_AUTH_FILE}" "$(cat "${WORK_DIR}/auth-path")" > "${WORK_DIR}/merged.json"
        mv "${WORK_DIR}/merged.json" "${REGISTRY_AUTH_FILE}"
        if [[ "${CI_USE_REGISTRY_PROXY}" == "true" ]]; then
            jq --arg registry "${KONFLUX_CATALOG_REGISTRY_PROXY}" --arg auth "${registry_auth}" \
                '.auths[$registry] = {auth: $auth}' "${REGISTRY_AUTH_FILE}" > "${WORK_DIR}/merged.json"
            mv "${WORK_DIR}/merged.json" "${REGISTRY_AUTH_FILE}"
        fi
    fi

    local original_auth_hash merged_auth_hash
    original_auth_hash=$(jq -S . "${WORK_DIR}/.dockerconfigjson" | sha256sum)
    merged_auth_hash=$(jq -S . "${REGISTRY_AUTH_FILE}" | sha256sum)
    if [[ "${original_auth_hash}" != "${merged_auth_hash}" ]]; then
        oc get mcp -o json > "${WORK_DIR}/mcp-before.json"
        if ! jq -e '.items | length > 0' "${WORK_DIR}/mcp-before.json" >/dev/null; then
            echo "ERROR: no MachineConfigPools found; cannot verify stage credential rollout"
            return 1
        fi
        oc set data secret/pull-secret -n openshift-config --from-file=".dockerconfigjson=${REGISTRY_AUTH_FILE}"
        local attempt
        for ((attempt=0; attempt<27; attempt++)); do
            oc get mcp -o json > "${WORK_DIR}/mcp-after.json"
            if jq -e --slurpfile before "${WORK_DIR}/mcp-before.json" '
                def state: [.metadata.generation, .status.observedGeneration,
                    .status.configuration.name, .status.updatedMachineCount,
                    .status.machineCount, .status.conditions];
                ((.items | map(.metadata.name) | sort) ==
                    ($before[0].items | map(.metadata.name) | sort)) and
                (.items | all(.[];
                    . as $pool |
                    if .status.machineCount == 0 then true else
                        (.status.conditions | any(.type == "Updated" and .status == "True")) and
                        (.status.conditions | all(.type != "Updating" or .status != "True")) and
                        (.status.observedGeneration == .metadata.generation) and
                        (.status.configuration.name == .spec.configuration.name) and
                        (.status.updatedMachineCount == .status.machineCount) and
                        (state != ($before[0].items[] | select(.metadata.name == $pool.metadata.name) | state))
                    end))
            ' "${WORK_DIR}/mcp-after.json" >/dev/null; then
                echo "MachineConfigPool stage credential rollout complete"
                return 0
            fi
            sleep 20
        done
        echo "ERROR: MachineConfigPool stage credential rollout timed out without verified convergence"
        return 1
    fi
}

set_proxy
mkdir -p "${TOOLS_DIR}"
export PATH="${TOOLS_DIR}:${PATH}"
install_oc
prepare_registry_auth
install_opm
run_command "oc whoami"
run_command "which oc && oc version -o yaml"
deploy_operators
