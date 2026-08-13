#!/bin/bash
# ==============================================================================
# Script to setup a custom FileBasedCatalog (FBC) CatalogSource on OpenShift
# for testing the secrets-store-csi-driver operator on s390x.
#
# This is adapted for CI environment with vault credentials.
# ==============================================================================

set -euo pipefail

# --- Configuration ---
# Check if TEST_GA_BUILD is set to true (case-insensitive)
TEST_GA_BUILD="${TEST_GA_BUILD:-false}"
if [[ "${TEST_GA_BUILD,,}" == "true" ]]; then
    USE_GA_BUILD=true
    echo "INFO: TEST_GA_BUILD is set to true - will use default catalog sources"
else
    USE_GA_BUILD=false
    echo "INFO: TEST_GA_BUILD is not set or false - will use custom FBC catalog"
fi

OPERATOR_NAME="ose-secrets-store-csi-driver-rhel9-operator"
FBC_IMAGE_REPO="quay.io/redhat-user-workloads/ocp-art-tenant/art-fbc"
FBC_CATALOG_NAME="art-fbc-catalog"
MIRROR_REPO="quay.io/redhat-user-workloads/ocp-art-tenant/art-images-share"

# Operator installation config
OPERATOR_NAMESPACE="openshift-cluster-csi-drivers"
OPERATORGROUP_NAME="secrets-store-csi-driver-og"
SUBSCRIPTION_NAME="secrets-store-csi-driver-operator"
SUBSCRIPTION_PACKAGE="secrets-store-csi-driver-operator"
SUBSCRIPTION_CHANNEL="stable"
CLUSTER_CSI_DRIVER_NAME="secrets-store.csi.k8s.io"
CSV_READY_TIMEOUT=300   # seconds to wait for CSV to reach Succeeded

# Pull secret from deploy-konflux credential (same as AWS weekly test)
PULL_SECRET_FILE="/var/run/secrets/pull-secret/.dockerconfigjson"
CLUSTER_PULL_SECRET_NAME="pull-secret"
CLUSTER_PULL_SECRET_NAMESPACE="openshift-config"

# Temp directory for oras pull output
WORK_DIR=$(mktemp -d)
trap 'rm -rf "${WORK_DIR}"' EXIT

# --- Helper: print a section header ---
section() {
    echo
    echo "======================================================================"
    echo "  $*"
    echo "======================================================================"
}

# ==============================================================================
# STEP 0: Architecture + Dependency Check
# ==============================================================================
check_arch_and_deps() {
    section "STEP 0: Architecture and Dependency Check"

    ARCH=$(uname -m)
    echo "Detected architecture: ${ARCH}"
    if [ "${ARCH}" != "s390x" ]; then
        echo "ERROR: This script is intended for s390x (IBM Z) architecture."
        echo "       Detected: ${ARCH}. Exiting."
        exit 1
    fi
    echo "Architecture check passed: s390x confirmed."

    echo
    echo "Checking required tools..."

    # --- dnf-installable packages ---
    for pkg in jq podman curl tar; do
        if ! command -v "${pkg}" &>/dev/null; then
            echo "Installing ${pkg} via dnf..."
            sudo dnf install -y "${pkg}" || {
                echo "ERROR: Failed to install ${pkg}."
                exit 1
            }
        else
            echo "  [OK] ${pkg}"
        fi
    done

    # --- oras: download s390x binary from GitHub releases if not present ---
    if ! command -v oras &>/dev/null; then
        echo "Installing oras (s390x)..."
        ORAS_VERSION="1.3.1"
        ORAS_TMP=$(mktemp -d)
        ORAS_TARBALL="oras_${ORAS_VERSION}_linux_s390x.tar.gz"
        ORAS_URL="https://github.com/oras-project/oras/releases/download/v${ORAS_VERSION}/${ORAS_TARBALL}"
        echo "   Downloading: ${ORAS_URL}"
        curl -fsSL "${ORAS_URL}" -o "${ORAS_TMP}/${ORAS_TARBALL}" || {
            echo "ERROR: Failed to download oras from ${ORAS_URL}."
            rm -rf "${ORAS_TMP}"
            exit 1
        }
        tar -xzf "${ORAS_TMP}/${ORAS_TARBALL}" -C "${ORAS_TMP}"
        sudo install -m 0755 "${ORAS_TMP}/oras" /usr/local/bin/oras
        rm -rf "${ORAS_TMP}"
        echo "  [OK] oras $(oras version | head -n1)"
    else
        echo "  [OK] oras ($(oras version | head -n1))"
    fi

    echo
    echo "All dependency checks passed."
}

# ==============================================================================
# STEP 1: Extract Cluster Version and Build FBC Image Tag
# ==============================================================================
extract_cluster_version() {
    section "STEP 1: Extracting OpenShift Cluster Version"

    OCP_FULL_VERSION=$(oc get clusterversion version \
        -o=jsonpath='{.status.desired.version}' 2>/dev/null)

    if [ -z "${OCP_FULL_VERSION}" ]; then
        echo "ERROR: Could not retrieve cluster version."
        exit 1
    fi

    # Extract 'X.Y' only (e.g. '4.21' from '4.21.3')
    OCP_VERSION=$(echo "${OCP_FULL_VERSION}" | cut -d. -f1,2)

    if [ -z "${OCP_VERSION}" ]; then
        echo "ERROR: Could not parse major.minor from version '${OCP_FULL_VERSION}'."
        exit 1
    fi

    # Build the final FBC image reference
    FINAL_FBC_IMAGE="${FBC_IMAGE_REPO}:ocp__${OCP_VERSION}__${OPERATOR_NAME}"

    echo "Cluster version  : ${OCP_FULL_VERSION}"
    echo "OCP version used : ${OCP_VERSION}"
    echo "FBC image        : ${FINAL_FBC_IMAGE}"
}

# ==============================================================================
# STEP 2: Disable Default CatalogSources
# ==============================================================================
disable_default_catalogs() {
    if [ "${USE_GA_BUILD}" = true ]; then
        section "STEP 2: Skipping - Using Default CatalogSources (TEST_GA_BUILD=true)"
        echo "Default CatalogSources will remain enabled for GA build testing."
        return 0
    fi

    section "STEP 2: Disabling All Default CatalogSources via OperatorHub"

    oc patch operatorhub cluster --type=json \
        -p='[{"op":"add","path":"/spec/disableAllDefaultSources","value":true}]'

    echo "Default CatalogSources disabled."
}

# ==============================================================================
# STEP 3: Merge Pull Secret
# ==============================================================================
merge_pull_secret() {
    section "STEP 3: Merging Pull Secret into Cluster Pull Secret"

    if [ ! -f "${PULL_SECRET_FILE}" ]; then
        echo "ERROR: Pull secret file not found at: ${PULL_SECRET_FILE}"
        exit 1
    fi

    # Validate that the pull secret file is valid JSON
    if ! jq empty "${PULL_SECRET_FILE}" 2>/dev/null; then
        echo "ERROR: '${PULL_SECRET_FILE}' is not valid JSON."
        exit 1
    fi

    echo "1. Fetching existing cluster pull secret..."
    EXISTING_SECRET_B64=$(oc get secret "${CLUSTER_PULL_SECRET_NAME}" \
        -n "${CLUSTER_PULL_SECRET_NAMESPACE}" \
        -o=jsonpath='{.data.\.dockerconfigjson}' 2>/dev/null)

    if [ -z "${EXISTING_SECRET_B64}" ]; then
        echo "ERROR: Could not read cluster pull secret."
        exit 1
    fi

    EXISTING_DOCKERCONFIG=$(echo "${EXISTING_SECRET_B64}" | base64 -d)

    echo "2. Merging new credentials into existing pull secret..."
    NEW_DOCKERCONFIG=$(cat "${PULL_SECRET_FILE}")

    # Deep-merge: new values override existing keys
    MERGED_DOCKERCONFIG=$(jq -s '.[0] * .[1]' \
        <(echo "${EXISTING_DOCKERCONFIG}") \
        <(echo "${NEW_DOCKERCONFIG}"))

    echo "3. Patching cluster pull secret..."
    MERGED_B64=$(echo "${MERGED_DOCKERCONFIG}" | base64 -w 0)

    oc patch secret "${CLUSTER_PULL_SECRET_NAME}" \
        -n "${CLUSTER_PULL_SECRET_NAMESPACE}" \
        --type=json \
        -p="[{\"op\":\"replace\",\"path\":\"/data/.dockerconfigjson\",\"value\":\"${MERGED_B64}\"}]"

    echo "Pull secret merged successfully."
}

# ==============================================================================
# STEP 4: Apply CatalogSource
# ==============================================================================
apply_catalog_source() {
    if [ "${USE_GA_BUILD}" = true ]; then
        section "STEP 4: Skipping - Not Creating Custom CatalogSource (TEST_GA_BUILD=true)"
        return 0
    fi

    section "STEP 4: Creating CatalogSource '${FBC_CATALOG_NAME}'"

    cat <<EOF | oc apply -f -
---
apiVersion: operators.coreos.com/v1alpha1
kind: CatalogSource
metadata:
  name: ${FBC_CATALOG_NAME}
  namespace: openshift-marketplace
spec:
  sourceType: grpc
  image: ${FINAL_FBC_IMAGE}
  displayName: "ART FBC for ${OPERATOR_NAME}"
  publisher: "Red Hat ART"
  updateStrategy:
    registryPoll:
      interval: 10m
EOF

    echo "CatalogSource applied."
}

# ==============================================================================
# STEP 5: Discover Related Images and Apply ImageDigestMirrorSet (IDMS)
# ==============================================================================
generate_and_apply_idms() {
    if [ "${USE_GA_BUILD}" = true ]; then
        section "STEP 5: Skipping - Not Creating IDMS (TEST_GA_BUILD=true)"
        return 0
    fi

    section "STEP 5: Generating and Applying ImageDigestMirrorSet (IDMS)"

    echo "1. Discovering attached artifacts from FBC image..."
    mapfile -t ARTIFACT_DIGESTS < <(
        oras discover --format json "${FINAL_FBC_IMAGE}" | \
        jq -r '.referrers[]
               | select(.artifactType == "application/vnd.konflux-ci.attached-artifact")
               | .digest'
    )

    if [ ${#ARTIFACT_DIGESTS[@]} -eq 0 ]; then
        echo "ERROR: No attached artifacts found on image '${FINAL_FBC_IMAGE}'."
        exit 1
    fi
    echo "   Found ${#ARTIFACT_DIGESTS[@]} attached artifact(s)"

    echo
    echo "2. Pulling all attached artifacts..."
    for DIGEST in "${ARTIFACT_DIGESTS[@]}"; do
        echo "   Pulling ${DIGEST}..."
        (
            cd "${WORK_DIR}"
            oras pull "${FBC_IMAGE_REPO}@${DIGEST}"
        )
    done

    RELATED_IMAGES_FILE="${WORK_DIR}/related-images.json"
    if [ ! -f "${RELATED_IMAGES_FILE}" ]; then
        echo "ERROR: 'related-images.json' was not found after pulling artifacts."
        exit 1
    fi

    echo "   Found related-images.json"

    echo
    echo "3. Parsing image list from related-images.json..."
    mapfile -t IMAGE_LIST < <(
        jq -r '.[]' "${RELATED_IMAGES_FILE}" | sed 's/@sha256:[a-f0-9]*//'
    )

    if [ ${#IMAGE_LIST[@]} -eq 0 ]; then
        echo "WARNING: No images found in related-images.json."
    else
        echo "   Found ${#IMAGE_LIST[@]} image(s) to mirror"
    fi

    echo
    echo "4. Building and applying ImageDigestMirrorSet..."

    MIRRORS_YAML=""
    for SOURCE_IMAGE in "${IMAGE_LIST[@]}"; do
        MIRRORS_YAML+="
  - mirrors:
    - ${MIRROR_REPO}
    source: ${SOURCE_IMAGE}"
    done

    IDMS_YAML=$(cat <<EOF
---
apiVersion: config.openshift.io/v1
kind: ImageDigestMirrorSet
metadata:
  name: ${OPERATOR_NAME}-images-mirror-set
spec:
  imageDigestMirrors:${MIRRORS_YAML}
EOF
)

    echo "${IDMS_YAML}" | oc apply -f -
    echo "IDMS applied."
}

# ==============================================================================
# STEP 6: Wait for CatalogSource to become READY
# ==============================================================================
wait_for_catalog_source() {
    if [ "${USE_GA_BUILD}" = true ]; then
        section "STEP 6: Skipping - No Custom CatalogSource (TEST_GA_BUILD=true)"
        return 0
    fi

    section "STEP 6: Waiting for CatalogSource '${FBC_CATALOG_NAME}' to become READY"

    local timeout=120
    local elapsed=0
    local interval=10

    echo "Polling every ${interval}s (timeout: ${timeout}s)..."
    while [ ${elapsed} -lt ${timeout} ]; do
        STATUS=$(oc get catalogsource "${FBC_CATALOG_NAME}" \
            -n openshift-marketplace \
            -o=jsonpath='{.status.connectionState.lastObservedState}' 2>/dev/null || true)

        if [ "${STATUS}" = "READY" ]; then
            echo "  CatalogSource is READY."
            return 0
        fi

        echo "  Current state: '${STATUS}' — waiting..."
        sleep ${interval}
        elapsed=$(( elapsed + interval ))
    done

    echo "ERROR: CatalogSource did not reach READY state within ${timeout}s."
    exit 1
}

# ==============================================================================
# STEP 7: Wait for MachineConfigPool rollout triggered by IDMS
# ==============================================================================
wait_for_mcp_rollout() {
    if [ "${USE_GA_BUILD}" = true ]; then
        section "STEP 7: Skipping - No MCP Rollout Needed (TEST_GA_BUILD=true)"
        return 0
    fi

    section "STEP 7: Waiting for MachineConfigPool Rollout (triggered by IDMS)"

    echo "IDMS changes trigger a MachineConfig update which reboots nodes."
    echo "Waiting for all MCPs to finish updating..."

    local timeout=900   # 15 min
    local elapsed=0
    local interval=30

    while [ ${elapsed} -lt ${timeout} ]; do
        UPDATING=$(oc get mcp -o=jsonpath='{range .items[*]}{.metadata.name}{" updating="}{.status.conditions[?(@.type=="Updating")].status}{"\n"}{end}' 2>/dev/null \
            | grep -c 'updating=True' || true)
        DEGRADED=$(oc get mcp -o=jsonpath='{range .items[*]}{.status.conditions[?(@.type=="Degraded")].status}{"\n"}{end}' 2>/dev/null \
            | grep -c 'True' || true)

        if [ "${DEGRADED}" -gt 0 ]; then
            echo "ERROR: One or more MachineConfigPools are Degraded."
            oc get mcp
            exit 1
        fi

        if [ "${UPDATING}" -eq 0 ]; then
            echo "  All MachineConfigPools are up to date."
            oc get mcp
            return 0
        fi

        echo "  ${UPDATING} MCP(s) still updating — waiting ${interval}s..."
        sleep ${interval}
        elapsed=$(( elapsed + interval ))
    done

    echo "ERROR: MachineConfigPool rollout did not complete within ${timeout}s."
    exit 1
}

# ==============================================================================
# STEP 8: Create Namespace + OperatorGroup + Subscription
# ==============================================================================
install_operator() {
    section "STEP 8: Installing Operator via Subscription"

    if ! oc get namespace "${OPERATOR_NAMESPACE}" &>/dev/null; then
        echo "Creating namespace '${OPERATOR_NAMESPACE}'..."
        oc create namespace "${OPERATOR_NAMESPACE}"
    else
        echo "Namespace '${OPERATOR_NAMESPACE}' already exists."
    fi

    echo
    echo "1. Applying OperatorGroup..."
    oc apply -f - <<EOF
apiVersion: operators.coreos.com/v1
kind: OperatorGroup
metadata:
  name: ${OPERATORGROUP_NAME}
  namespace: ${OPERATOR_NAMESPACE}
spec: {}
EOF

    echo
    echo "2. Applying Subscription..."
    
    if [ "${USE_GA_BUILD}" = true ]; then
        CATALOG_SOURCE="redhat-operators"
    else
        CATALOG_SOURCE="${FBC_CATALOG_NAME}"
    fi
    
    oc apply -f - <<EOF
apiVersion: operators.coreos.com/v1alpha1
kind: Subscription
metadata:
  name: ${SUBSCRIPTION_NAME}
  namespace: ${OPERATOR_NAMESPACE}
spec:
  channel: ${SUBSCRIPTION_CHANNEL}
  installPlanApproval: Automatic
  name: ${SUBSCRIPTION_PACKAGE}
  source: ${CATALOG_SOURCE}
  sourceNamespace: openshift-marketplace
EOF

    echo "Subscription created."
}

# ==============================================================================
# STEP 9: Wait for CSV to reach Succeeded
# ==============================================================================
wait_for_csv() {
    section "STEP 9: Waiting for CSV to reach 'Succeeded' Phase"

    local elapsed=0
    local interval=15

    echo "Polling every ${interval}s (timeout: ${CSV_READY_TIMEOUT}s)..."

    while [ ${elapsed} -lt ${CSV_READY_TIMEOUT} ]; do
        CSV_NAME=$(oc get subscription "${SUBSCRIPTION_NAME}" \
            -n "${OPERATOR_NAMESPACE}" \
            -o=jsonpath='{.status.installedCSV}' 2>/dev/null || true)

        if [ -n "${CSV_NAME}" ]; then
            CSV_PHASE=$(oc get csv "${CSV_NAME}" \
                -n "${OPERATOR_NAMESPACE}" \
                -o=jsonpath='{.status.phase}' 2>/dev/null || true)

            echo "  CSV: ${CSV_NAME}  Phase: ${CSV_PHASE}"

            if [ "${CSV_PHASE}" = "Succeeded" ]; then
                echo
                echo "CSV reached Succeeded."
                oc get csv "${CSV_NAME}" -n "${OPERATOR_NAMESPACE}"
                return 0
            fi

            if [ "${CSV_PHASE}" = "Failed" ]; then
                echo "ERROR: CSV '${CSV_NAME}' has Failed."
                exit 1
            fi
        else
            echo "  InstallPlan not yet created — waiting..."
        fi

        sleep ${interval}
        elapsed=$(( elapsed + interval ))
    done

    echo "ERROR: CSV did not reach 'Succeeded' within ${CSV_READY_TIMEOUT}s."
    exit 1
}

# ==============================================================================
# STEP 10: Create ClusterCSIDriver
# ==============================================================================
create_cluster_csi_driver() {
    section "STEP 10: Creating ClusterCSIDriver '${CLUSTER_CSI_DRIVER_NAME}'"

    oc apply -f - <<EOF
apiVersion: operator.openshift.io/v1
kind: ClusterCSIDriver
metadata:
  name: ${CLUSTER_CSI_DRIVER_NAME}
spec:
  managementState: Managed
EOF

    echo "ClusterCSIDriver '${CLUSTER_CSI_DRIVER_NAME}' applied."
}

# ==============================================================================
# STEP 11: Verify Operator and Operand Pods
# ==============================================================================
verify_pods() {
    section "STEP 11: Verifying Operator and Operand Pods"

    local timeout=300
    local elapsed=0
    local interval=15

    echo "Waiting for secrets-store pods to be Running..."

    while [ ${elapsed} -lt ${timeout} ]; do
        NOT_RUNNING=$(oc get pods -n "${OPERATOR_NAMESPACE}" \
            --no-headers 2>/dev/null \
            | grep -i secrets \
            | grep -cv 'Running' || true)

        RUNNING=$(oc get pods -n "${OPERATOR_NAMESPACE}" \
            --no-headers 2>/dev/null \
            | grep -i secrets \
            | grep -c 'Running' || true)

        if [ "${RUNNING}" -gt 0 ] && [ "${NOT_RUNNING}" -eq 0 ]; then
            echo "  All secrets-store pods are Running:"
            oc get pods -n "${OPERATOR_NAMESPACE}" | grep -i secrets
            return 0
        fi

        echo "  Running: ${RUNNING}  Not yet Running: ${NOT_RUNNING} — waiting..."
        sleep ${interval}
        elapsed=$(( elapsed + interval ))
    done

    echo "WARNING: Not all pods reached Running state within ${timeout}s."
    oc get pods -n "${OPERATOR_NAMESPACE}" | grep -i secrets || true
}

# ==============================================================================
# Main
# ==============================================================================
check_arch_and_deps
extract_cluster_version
disable_default_catalogs
merge_pull_secret
apply_catalog_source
generate_and_apply_idms
wait_for_mcp_rollout
wait_for_catalog_source
install_operator
wait_for_csv
create_cluster_csi_driver
verify_pods

section "Setup Complete"
echo "Secrets Store CSI Driver operator is installed and ready for testing."
