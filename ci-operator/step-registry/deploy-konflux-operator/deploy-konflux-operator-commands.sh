#!/bin/bash
#
# This step deploys Konflux-built operators onto the cluster under test.
#
# The deployment logic below (see write_deploy_operator_script) is vendored from the
# project this step used to clone at run time:
#
#   upstream        : https://github.com/ajaggapa/deploy-konflux-operator
#   file            : deploy-operator.sh
#   tag             : v8.1
#   commit          : 8b1833e2592825b007525219e28fd9fffaef4a89
#   upstream sha256 : 9fdc0046fb7de8c3b809d371df7fbfadaef9d63e26ace7950c2a9085ed63f9dc
#   authors         : Martin Gencur, Anvesh Jaggapatruni
#
# That project publishes no LICENSE file, so the terms covering this copy are not stated
# upstream. See the pull request that introduced this file for the provenance record.
#
# The copy is not byte-for-byte identical to that upstream file. One normalisation was
# applied, and nothing else:
#
#   sed 's/[ \t]*$//'   -- remove trailing horizontal whitespace
#
# It changes 21 lines (57 bytes) that this repository's clean-diff gate rejects. Each is
# either a whitespace-only line or a single space after a shell token; none ends in a
# backslash and none lies inside a here-document body or a quoted string, so no string,
# here-document or line continuation is affected. `shfmt -ln bash` produces identical
# canonical output for the upstream file and for this copy, which is the parse-tree proof
# that the normalisation carries no meaning.
#
#   embedded sha256 : 4c1c8f552d486addf908f266d2a7a0f9f7b877c599b44e27f7341c85223cb4e6
#
# which is the sha256 of `sed 's/[ \t]*$//' deploy-operator.sh` at the commit above, so the
# copy below can be reproduced from upstream and checked.
#
# Apart from that normalisation the logic is unchanged, so moving it here changed nothing
# about what it does. This file is now the only place the deployment logic lives, so later
# fixes land here and will make it diverge from that base; the provenance block is not
# re-synced.
#

set -e
set -u
set -o pipefail

declare -r PULL_SECRET=/var/run/vault/deploy-konflux-operator-art-image-share
declare -r TOOLS_DIR=/tmp/bin
declare -r MIRROR_REGISTRY_DIR="${MIRROR_REGISTRY_DIR:-"/var/run/vault/mirror-registry"}"
declare -r MIRROR_REGISTRY_CREDS="${MIRROR_REGISTRY_DIR}/registry_creds"
declare -r USE_REGISTRY_PROXY="${KONFLUX_USE_REGISTRY_PROXY:-false}"
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
    auth_file=$(mktemp)
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

# opm is taken from the OpenShift operator-registry image rather than downloaded from the
# upstream operator-framework project. The image is in the openshift organisation on
# quay.io and is built from github.com/openshift/operator-framework-olm.
#
# quay.io is deliberately the host: the deployment script renders its catalogs from
# quay.io/redhat-user-workloads/ocp-art-tenant/art-fbc and mirrors from
# quay.io/redhat-user-workloads/ocp-art-tenant/art-images-share, so any job that actually
# uses opm already has to reach quay.io. Taking opm from the same host therefore adds no
# registry that the step did not already need. (An earlier revision of this step used
# registry.redhat.io; that host is only contacted by the cluster's own nodes when they
# pull operator images, never by this step, so it would have been a new dependency.)
#
# The reference is a digest so the binary cannot change underneath the step.
#
# The version is pinned rather than taken from the cluster's own payload, because the
# payload build has to match the cluster and not every build can render the catalogs this
# step uses. Those catalogs are multi-arch OCI indexes and are referenced by tag; the
# 4.20 and 4.23 builds fail such a reference ('Invalid image' / empty output), while
# 4.14, 4.16 and 5.0 handle it. The 4.14 build is also the most portable one: it needs
# only GLIBC_2.28, so it runs on both RHEL 8 and RHEL 9 test images, whereas later builds
# need GLIBC_2.34.
#
# Output was compared against the previously used upstream v1.26.2 build over the five
# predefined operators on 4.23 and 5.0: byte-identical on 4.23, and identical apart from
# JSON key ordering on 5.0, which the deployment script does not depend on because it
# parses with jq.
#
# The binary is staged in a scratch directory and only installed once it has been shown
# to run, so ${TOOLS_DIR} never holds a partial or unusable binary.
declare -r OPM_IMAGE=quay.io/openshift/origin-operator-registry@sha256:f3986f2395c248aaa36bfb33e44d258841013958106d1efb4c842ba78a3a8e2d

function install_opm() {
    echo "Install opm"
    local scratch pull_secret err="" encoded="" out=""
    local auth_args=()

    scratch=$(mktemp -d)
    pull_secret="${scratch}/pull-secret.json"

    # The opm image is public, but pass the cluster's pull-secret when it can be read so
    # that quay.io is reached with the same credentials the rest of the step uses. Keep
    # the secret in a variable and a scratch file only; never log it.
    encoded=$(oc get secret pull-secret -n openshift-config \
                -o jsonpath='{.data.\.dockerconfigjson}' 2>&1) \
        || { err="${encoded}"; encoded=""; }
    if [[ -n "${encoded}" ]]; then
        printf '%s' "${encoded}" | base64 -d > "${pull_secret}" 2>/dev/null \
            || { err="could not decode the cluster pull-secret"; rm -f "${pull_secret}"; }
    fi
    if [[ -s "${pull_secret}" ]]; then
        auth_args=(-a "${pull_secret}")
    fi

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

    # The deployment script exits before it checks for opm when operator deployment is
    # switched off, so a missing opm is not fatal in that case.
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
# what actually puts it ahead of any older oc baked into the test image, exactly as the
# previous download did.
function install_oc() {
    echo "Install oc"
    run_command "cp ${CLI_DIR:-/cli}/oc ${TOOLS_DIR}/oc && chmod +x ${TOOLS_DIR}/oc"
}

function install_deps() {
    run_command "mkdir -p ${TOOLS_DIR}"
    run_command "export PATH=${TOOLS_DIR}:${PATH}"
    install_oc # we need a modern client, and install_opm below uses it
    install_opm
}

# write_deploy_operator_script materialises the vendored deployment script.
#
# Only the file named by the `commands` field of a step reference is shipped into the step
# container; sibling files in a step-registry directory are never read by ci-operator. The
# deployment script is therefore embedded here as a quoted here-document rather than kept
# next to this file or cloned at run time.
function write_deploy_operator_script() {
    local target="$1"
    cat > "${target}" <<'DEPLOY_KONFLUX_OPERATOR_V8_1_SCRIPT_EOF'
#!/bin/bash

set -Eeuo pipefail

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
        --quay-auth)
            QUAY_AUTH="$2"
            log "INFO" "Quay auth file specified: $2"
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
        if [[ ! " $VALID_OPERATORS " =~ " $op " ]]; then
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

# Check if quay-auth is required for disconnected clusters
if [[ -n "${INTERNAL_REGISTRY:-}" && -z "${QUAY_AUTH:-}" ]]; then
    log "ERROR" "--quay-auth is required for disconnected clusters with internal registry"
    exit 1
fi

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

# Check podman (required for disconnected clusters with internal registry)
if [[ "$DISCONNECTED" == true && "$USE_REGISTRY_PROXY" == false ]]; then
    log "INFO" "Checking for podman (required for registry authentication)..."
    command -v "podman" >/dev/null 2>&1 || { log "ERROR" "podman not installed (required for registry authentication)"; exit 1; }
    log "SUCCESS" "podman is available"
else
    log "INFO" "Skipping podman check (not needed for connected clusters without quay-auth)"
fi

log "SUCCESS" "All required tools are available"

log "INFO" "Validating authentication files"

# Only validate quay auth file if provided
if [[ -n "${QUAY_AUTH:-}" ]]; then
    log "INFO" "Validating quay auth file: $QUAY_AUTH"
    [[ ! -f "$QUAY_AUTH" ]] && { log "ERROR" "Quay auth file not found"; exit 1; }
    jq empty "$QUAY_AUTH" 2>/dev/null || { log "ERROR" "Invalid JSON in quay auth"; exit 1; }
    log "SUCCESS" "Quay auth file is valid"
else
    log "INFO" "No quay auth file provided"
fi

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
update_cluster_pull_secret() {
    local auth_file=$1

    log "INFO" "Updating cluster pull-secret with content of $auth_file"

    log "INFO" "Retrieving current cluster pull-secret..."
    current_pull_secret=$(oc get secret pull-secret -n openshift-config -o jsonpath='{.data.\.dockerconfigjson}' | base64 -d)
    log "SUCCESS" "Retrieved current pull-secret"

    log "INFO" "Merging pull-secrets..."
    auth_content=$(cat "$auth_file")

    # Create a temporary file for the merged auth
    merged_auth_file=$(mktemp)

    # Create temporary files for the JSON inputs
    current_auth_file=$(mktemp)
    new_auth_file=$(mktemp)
    echo "$current_pull_secret" > "$current_auth_file"
    echo "$auth_content" > "$new_auth_file"

    # Debug: Check the content of the files
    log "INFO" "Debugging JSON inputs..."
    log "INFO" "Current pull-secret file size: $(wc -c < "$current_auth_file") bytes"
    log "INFO" "Auth file size: $(wc -c < "$new_auth_file") bytes"

    # Validate JSON inputs before merging
    if ! jq empty "$current_auth_file" 2>/dev/null; then
        log "ERROR" "Current pull-secret is not valid JSON"
        log "ERROR" "First 200 chars of current pull-secret: $(head -c 200 "$current_auth_file")"
        rm -f "$current_auth_file" "$new_auth_file" "$merged_auth_file"
        exit 1
    fi

    if ! jq empty "$new_auth_file" 2>/dev/null; then
        log "ERROR" "Auth content is not valid JSON"
        log "ERROR" "First 200 chars of auth: $(head -c 200 "$new_auth_file")"
        rm -f "$current_auth_file" "$new_auth_file" "$merged_auth_file"
        exit 1
    fi

    # Check if both files have the expected structure
    if ! jq -e '.auths' "$current_auth_file" >/dev/null 2>&1; then
        log "ERROR" "Current pull-secret does not contain 'auths' field"
        log "ERROR" "Current pull-secret structure: $(jq keys "$current_auth_file" 2>/dev/null || echo 'Invalid JSON')"
        rm -f "$current_auth_file" "$new_auth_file" "$merged_auth_file"
        exit 1
    fi

    if ! jq -e '.auths' "$new_auth_file" >/dev/null 2>&1; then
        log "ERROR" "Auth does not contain 'auths' field"
        log "ERROR" "Auth structure: $(jq keys "$new_auth_file" 2>/dev/null || echo 'Invalid JSON')"
        rm -f "$current_auth_file" "$new_auth_file" "$merged_auth_file"
        exit 1
    fi

    log "INFO" "Both JSON files are valid and contain 'auths' fields"

    jq -s '
        .[0].auths as $current |
        .[1].auths as $new |
        {
            auths: ($current + $new)
        }
    ' "$current_auth_file" "$new_auth_file" > "$merged_auth_file"

    # Cleanup temporary files
    rm -f "$current_auth_file" "$new_auth_file"

    # Apply the merged auth
    log "INFO" "Comparing current and updated pull-secret..."
    if ! cmp -s <(echo "$current_pull_secret" | jq -S) "$merged_auth_file"; then
        log "INFO" "Updating cluster pull-secret..."
        cat "$merged_auth_file" | oc set data secret/pull-secret -n openshift-config --from-file=.dockerconfigjson=/dev/stdin || \
            { log "ERROR" "Failed to update cluster pull-secret"; rm -f "$merged_auth_file"; exit 1; }
        log "SUCCESS" "Updated cluster pull-secret"
    else
        log "SUCCESS" "Pull-secret already contains all required credentials"
    fi

    # Cleanup
    rm -f "$merged_auth_file"
}

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
            registry_target="${INTERNAL_REGISTRY_PROXY:-}"
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
ART_IMAGES_SOURCE="quay.io/redhat-user-workloads/ocp-art-tenant/art-images-share"
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

# Authenticate registries

if [[ "$DISCONNECTED" == true ]]; then
    # Authenticate to internal registry for mirroring
    if [[ "$USE_REGISTRY_PROXY" == false ]]; then
        quay_auth_b64=""
        quay_auth_source=""

        # Priority 1: Try specific repository auth (quay.io/redhat-user-workloads/ocp-art-tenant/art-images-share)
        quay_auth_key=$(jq -r '.auths | to_entries[] | select(.key | contains("quay.io/redhat-user-workloads/ocp-art-tenant/art-images-share")) | .key' "$QUAY_AUTH" 2>/dev/null | head -1)
        if [[ -n "$quay_auth_key" ]]; then
            quay_auth_b64=$(jq -r --arg key "$quay_auth_key" '.auths[$key].auth' "$QUAY_AUTH" 2>/dev/null)
            quay_auth_source="$quay_auth_key"
        fi

        # Priority 2: Try broader repository auth (quay.io/redhat-user-workloads)
        if [[ -z "$quay_auth_b64" ]]; then
            quay_auth_key=$(jq -r '.auths | to_entries[] | select(.key | contains("quay.io/redhat-user-workloads")) | .key' "$QUAY_AUTH" 2>/dev/null | head -1)
            if [[ -n "$quay_auth_key" ]]; then
                quay_auth_b64=$(jq -r --arg key "$quay_auth_key" '.auths[$key].auth' "$QUAY_AUTH" 2>/dev/null)
                quay_auth_source="$quay_auth_key"
            fi
        fi

        # Priority 3: Fall back to general quay.io domain auth
        if [[ -z "$quay_auth_b64" ]]; then
            quay_auth_key=$(jq -r '.auths | to_entries[] | select(.key | test("^(https://)?quay\\.io/?$")) | .key' "$QUAY_AUTH" 2>/dev/null | head -1)
            if [[ -n "$quay_auth_key" ]]; then
                quay_auth_b64=$(jq -r --arg key "$quay_auth_key" '.auths[$key].auth' "$QUAY_AUTH" 2>/dev/null)
                quay_auth_source="$quay_auth_key"
            fi
        fi

        if [[ -n "$quay_auth_b64" ]]; then
            quay_user=$(echo "$quay_auth_b64" | base64 -d | cut -d: -f1)
            quay_pass=$(echo "$quay_auth_b64" | base64 -d | cut -d: -f2-)
            echo "Authenticating to quay.io using credentials from: $quay_auth_source"
            echo "  Username: $quay_user"
            echo "$quay_pass" | podman login --username "$quay_user" --password-stdin quay.io >/dev/null 2>&1
        else
            echo "Authenticating to quay.io using authfile: $QUAY_AUTH"
            podman login --authfile="$QUAY_AUTH" quay.io >/dev/null 2>&1
        fi || { echo "ERROR: Failed to auth quay.io" >&2; exit 1; }

        internal_auth_b64=$(jq -r --arg reg "$INTERNAL_REGISTRY" '.auths[$reg].auth // empty' "$INTERNAL_REGISTRY_AUTH" 2>/dev/null)
        if [[ -n "$internal_auth_b64" ]]; then
            internal_user=$(echo "$internal_auth_b64" | base64 -d | cut -d: -f1)
            internal_pass=$(echo "$internal_auth_b64" | base64 -d | cut -d: -f2-)
            echo "$internal_pass" | podman login --username "$internal_user" --password-stdin "$INTERNAL_REGISTRY" >/dev/null 2>&1
        else
            podman login --authfile="$INTERNAL_REGISTRY_AUTH" "$INTERNAL_REGISTRY" >/dev/null 2>&1
        fi || { echo "ERROR: Failed to auth internal registry" >&2; exit 1; }
    else
        # When using proxy in disconnected mode, update cluster pull-secret with internal registry proxy auth
        update_cluster_pull_secret "$INTERNAL_REGISTRY_PROXY_AUTH"
    fi
else
    # Connected mode - update pull-secret with quay auth if provided
    if [[ -n "${QUAY_AUTH:-}" ]]; then
        update_cluster_pull_secret "$QUAY_AUTH"
    fi
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
        mirror_output=$(oc image mirror --keep-manifest-list=true "$fbc_source" "$fbc_target" 2>&1)
        mirror_status=$?
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
    # Merge quay and internal auth files for oc image mirror (pull+push)
    MERGED_AUTH_FILE=$(mktemp)
    jq -s '{auths: (.[0].auths + .[1].auths)}' "$QUAY_AUTH" "$INTERNAL_REGISTRY_AUTH" > "$MERGED_AUTH_FILE" || \
        { echo "ERROR: Failed to merge auth files for image mirroring" >&2; rm -f "$MERGED_AUTH_FILE" "$ALL_IMAGES_FILE"; exit 1; }

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
        source="${ART_IMAGES_SOURCE}@${digest}"
        target="${INTERNAL_REGISTRY}/redhat-user-workloads/ocp-art-tenant/art-images-share"

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
    IDMS_MIRROR="${mirror_registry}/redhat-user-workloads/ocp-art-tenant/art-images-share"
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
        while IFS= read -r repo; do
            [[ -z "$repo" ]] && continue
            echo "  - mirrors:
    - ${IDMS_MIRROR}
    source: $repo"
        done < <(echo "$bundle_data" | jq -r '.relatedImages[]?.image // empty' | grep -v '^$' | sed 's/@sha256:[a-f0-9]\{64\}$//' | sort -u)
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
log "INFO" "Disabling default catalogs..."
oc patch operatorhub cluster -p '{"spec": {"disableAllDefaultSources": true}}' --type=merge || \
    { log "ERROR" "Failed to disable default catalogs"; exit 1; }
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

DEPLOY_KONFLUX_OPERATOR_V8_1_SCRIPT_EOF
}

function deploy_operators() {
    run_command "cd $(mktemp -d)"
    run_command "mkdir -p deploy-konflux-operator"
    write_deploy_operator_script deploy-konflux-operator/deploy-operator.sh
    run_command "chmod -R a+x deploy-konflux-operator"

    declare args=()
    if [[ -n "${KONFLUX_TARGET_OPERATORS:-}" ]]; then
        args+=(--operator "${KONFLUX_TARGET_OPERATORS}")
    fi
    if [[ -n "${KONFLUX_TARGET_FBC_TAGS:-}" ]]; then
        args+=(--fbc-tag "${KONFLUX_TARGET_FBC_TAGS}")
    fi

    local mirror_registry_creds
    mirror_registry_creds=$(head -n 1 "${MIRROR_REGISTRY_CREDS}" | base64 -w 0)

    if [[ "${DISCONNECTED:-false}" == "true" ]]; then
        local mirror_registry_url
        mirror_registry_url=$(head -n 1 "${SHARED_DIR}/mirror_registry_url")

        # Configure registry proxy if enabled
        if [[ "${USE_REGISTRY_PROXY:-false}" == "true" ]]; then
            # Set proxy port (default: 6003)
            local registry_proxy_port="${REGISTRY_PROXY_PORT:-6003}"
            local registry_proxy_url

            # Determine proxy URL: use explicit host if provided, otherwise derive from mirror registry
            if [[ -n "${REGISTRY_PROXY_HOST:-}" ]]; then
                # Use explicitly provided proxy host and port
                registry_proxy_url="${REGISTRY_PROXY_HOST}:${REGISTRY_PROXY_PORT}"
            else
                # Derive proxy URL from mirror registry by replacing port 5000 with proxy port.
                # This is for cases where registry proxy is derived from mirror registry url,
                # but just running on a different port.
                registry_proxy_url="${mirror_registry_url//5000/${registry_proxy_port}}"
            fi

            local registry_proxy_auth
            registry_proxy_auth=$(create_registry_auth "${registry_proxy_url}" "${mirror_registry_creds}")
            args+=(--internal-registry-proxy "${registry_proxy_url}" --internal-registry-proxy-auth "${registry_proxy_auth}")
        else
            local registry_auth
            registry_auth=$(create_registry_auth "${mirror_registry_url}" "${mirror_registry_creds}")
            args+=(--internal-registry "${mirror_registry_url}" --internal-registry-auth "${registry_auth}" --quay-auth "${PULL_SECRET}/.dockerconfigjson")
        fi
    else
        args+=(--quay-auth "${PULL_SECRET}/.dockerconfigjson")
    fi

    run_command "deploy-konflux-operator/deploy-operator.sh ${args[*]}"
}

set_proxy
install_deps
run_command "oc whoami"
run_command "which oc && oc version -o yaml"
deploy_operators
