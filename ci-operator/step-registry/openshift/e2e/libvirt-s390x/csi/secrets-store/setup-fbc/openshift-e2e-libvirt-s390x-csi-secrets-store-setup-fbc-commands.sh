#!/bin/bash
# ==============================================================================
# Script to setup a custom FileBasedCatalog (FBC) CatalogSource on OpenShift
# for testing the secrets-store-csi-driver operator on s390x.
#
# This is adapted for CI environment with vault credentials.
# ==============================================================================

set -euo pipefail

# Setup unprivileged tool installation path
export PATH="/tmp/bin:${PATH}"
mkdir -p /tmp/bin

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
CSV_READY_TIMEOUT=900   # seconds to wait for CSV to reach Succeeded

# Pull secret from deploy-konflux credential (same as AWS weekly test)
PULL_SECRET_FILE="/var/run/secrets/pull-secret/.dockerconfigjson"
CLUSTER_PULL_SECRET_NAME="pull-secret"
CLUSTER_PULL_SECRET_NAMESPACE="openshift-config"

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

    CLUSTER_ARCH=$(oc get nodes -o jsonpath='{.items[0].status.nodeInfo.architecture}' 2>/dev/null || echo "unknown")
    echo "Detected cluster architecture: ${CLUSTER_ARCH}"
    if [ "${CLUSTER_ARCH}" != "s390x" ]; then
        echo "ERROR: This script is intended for s390x (IBM Z) clusters."
        echo "       Detected cluster architecture: ${CLUSTER_ARCH}. Exiting."
        exit 1
    fi
    echo "Architecture check passed: s390x cluster confirmed."

    echo
    echo "Checking required tools..."

    # Verify tools already present in the step image (ocp/cli-jq).
    for tool in oc jq; do
        if ! command -v "${tool}" &>/dev/null; then
            echo "ERROR: Required tool '${tool}' not found in PATH."
            exit 1
        fi
        echo "  [OK] ${tool}"
    done

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

    if [ -n "${FBC_IMAGE:-}" ]; then
        FINAL_FBC_IMAGE="${FBC_IMAGE}"
        echo "Using FBC_IMAGE override: ${FINAL_FBC_IMAGE}"
    else
        FINAL_FBC_IMAGE="${FBC_IMAGE_REPO}:ocp__${OCP_VERSION}__${OPERATOR_NAME}"
    fi

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
    # Disable tracing due to pull-secret handling
    [[ $- == *x* ]] && WAS_TRACING=true || WAS_TRACING=false
    set +x
    mkdir -p /tmp/sscsi-pull-secret
    oc extract secret/"${CLUSTER_PULL_SECRET_NAME}" \
        -n "${CLUSTER_PULL_SECRET_NAMESPACE}" \
        --confirm --to /tmp/sscsi-pull-secret
    if [ ! -f /tmp/sscsi-pull-secret/.dockerconfigjson ]; then
        echo "ERROR: Could not read cluster pull secret."
        $WAS_TRACING && set -x
        exit 1
    fi

    echo "2. Merging new credentials into existing pull secret..."
    jq -s '.[0].auths += .[1].auths | .[0]' \
        /tmp/sscsi-pull-secret/.dockerconfigjson \
        "${PULL_SECRET_FILE}" > /tmp/sscsi-merged-pullsecret.json

    echo "3. Patching cluster pull secret..."
    oc set data secret/"${CLUSTER_PULL_SECRET_NAME}" \
        -n "${CLUSTER_PULL_SECRET_NAMESPACE}" \
        --from-file=.dockerconfigjson=/tmp/sscsi-merged-pullsecret.json
    rm -rf /tmp/sscsi-pull-secret /tmp/sscsi-merged-pullsecret.json
    $WAS_TRACING && set -x

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
  grpcPodConfig:
    extractContent:
      cacheDir: /tmp/cache
      catalogDir: /configs
    memoryTarget: 30Mi
  updateStrategy:
    registryPoll:
      interval: 10m
EOF

    echo "CatalogSource applied."
}

# ==============================================================================
# STEP 5: Apply ImageDigestMirrorSet (IDMS)
#
# Hardcoded mirrors matching the working AWS weekly job, plus openshift5
# sources (CRO s390x pattern). Dynamic oras discover is not used: oras runs
# on the CI pod, which has no registry auth for art-fbc.
# ==============================================================================
generate_and_apply_idms() {
    if [ "${USE_GA_BUILD}" = true ]; then
        section "STEP 5: Skipping - Not Creating IDMS (TEST_GA_BUILD=true)"
        return 0
    fi

    section "STEP 5: Applying ImageDigestMirrorSet (IDMS)"

    cat <<EOF | oc apply -f -
apiVersion: config.openshift.io/v1
kind: ImageDigestMirrorSet
metadata:
  name: ${OPERATOR_NAME}-images-mirror-set
spec:
  imageDigestMirrors:
  - mirrors:
    - ${MIRROR_REPO}
    source: registry.redhat.io/openshift4/ose-secrets-store-csi-driver-rhel9-operator
  - mirrors:
    - ${MIRROR_REPO}
    source: registry.redhat.io/openshift4/ose-secrets-store-csi-driver-operator-bundle
  - mirrors:
    - ${MIRROR_REPO}
    source: registry.redhat.io/openshift4/ose-secrets-store-csi-driver-rhel9
  - mirrors:
    - ${MIRROR_REPO}
    source: registry.redhat.io/openshift4/ose-csi-node-driver-registrar-rhel9
  - mirrors:
    - ${MIRROR_REPO}
    source: registry.redhat.io/openshift4/ose-csi-livenessprobe-rhel9
  - mirrors:
    - ${MIRROR_REPO}
    source: registry.redhat.io/openshift5/ose-secrets-store-csi-driver-rhel9-operator
  - mirrors:
    - ${MIRROR_REPO}
    source: registry.redhat.io/openshift5/ose-secrets-store-csi-driver-operator-bundle
  - mirrors:
    - ${MIRROR_REPO}
    source: registry.redhat.io/openshift5/ose-secrets-store-csi-driver-rhel9
  - mirrors:
    - ${MIRROR_REPO}
    source: registry.redhat.io/openshift5/ose-csi-node-driver-registrar-rhel9
  - mirrors:
    - ${MIRROR_REPO}
    source: registry.redhat.io/openshift5/ose-csi-livenessprobe-rhel9
EOF

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

    local timeout=600
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
    echo "If the FBC tag does not exist for this OCP version, set FBC_IMAGE on the job."
    oc get catalogsource "${FBC_CATALOG_NAME}" -n openshift-marketplace -o yaml || true
    oc get pods -n openshift-marketplace -l "olm.catalogSource=${FBC_CATALOG_NAME}" -o wide || true
    oc describe pods -n openshift-marketplace -l "olm.catalogSource=${FBC_CATALOG_NAME}" || true
    exit 1
}

# ==============================================================================
# STEP 7: Wait for MachineConfigPool rollout triggered by pull-secret / IDMS
# ==============================================================================
mcp_rollout_in_progress() {
    oc get mcp -o json | jq -e '
      [.items[] | select(
        ((.status.machineCount // 0) != (.status.updatedMachineCount // 0))
        or ([.status.conditions[]? | select(.type=="Updating" and .status=="True")] | length > 0)
      )] | length > 0
    ' >/dev/null
}

wait_for_mcp_rollout() {
    if [ "${USE_GA_BUILD}" = true ]; then
        section "STEP 7: Skipping - No MCP Rollout Needed (TEST_GA_BUILD=true)"
        return 0
    fi

    section "STEP 7: Waiting for MachineConfigPool Rollout (triggered by IDMS)"

    echo "Pull-secret and IDMS changes trigger a MachineConfig update which reboots nodes."
    echo "Giving the MCO time to render the new MachineConfig..."
    sleep 60
    oc get mcp

    local start_deadline=$((SECONDS + 180))
    local rollout_started=false
    echo "Waiting up to 3m for an MCP rollout to start..."
    while (( SECONDS < start_deadline )); do
        if mcp_rollout_in_progress; then
            rollout_started=true
            break
        fi
        sleep 10
    done

    if [ "${rollout_started}" = true ]; then
        echo "MCP rollout detected; waiting for Updated..."
    else
        echo "No MCP rollout detected within 3m; waiting for Updated anyway (may already be current)."
    fi

    oc wait mcp/master --for condition=Updated --timeout=30m
    oc wait mcp/worker --for condition=Updated --timeout=30m
    oc get mcp
    echo "MachineConfigPools are Updated."
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
    echo "1. Ensuring OperatorGroup..."
    # OLM allows only one OperatorGroup per namespace. openshift-cluster-csi-drivers
    # already has one for in-cluster CSI operators — do not create a second, and
    # do not rewrite its targetNamespaces (that would affect other CSI operators).
    local og_names
    og_names=$(oc get operatorgroup -n "${OPERATOR_NAMESPACE}" -o jsonpath='{.items[*].metadata.name}' 2>/dev/null || true)
    local og_count
    og_count=$(echo "${og_names}" | wc -w | tr -d ' ')

    if [ "${og_count}" -gt 1 ]; then
        echo "ERROR: multiple OperatorGroups in namespace '${OPERATOR_NAMESPACE}': ${og_names}"
        oc get operatorgroup -n "${OPERATOR_NAMESPACE}" -o yaml || true
        exit 1
    elif [ -n "${og_names}" ]; then
        echo "Using existing OperatorGroup '${og_names}'."
        oc get operatorgroup "${og_names}" -n "${OPERATOR_NAMESPACE}"
    else
        echo "No OperatorGroup found; creating '${OPERATORGROUP_NAME}'."
        oc apply -f - <<EOF
apiVersion: operators.coreos.com/v1
kind: OperatorGroup
metadata:
  name: ${OPERATORGROUP_NAME}
  namespace: ${OPERATOR_NAMESPACE}
spec: {}
EOF
    fi

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
                oc get csv "${CSV_NAME}" -n "${OPERATOR_NAMESPACE}" -o yaml || true
                oc get events -n "${OPERATOR_NAMESPACE}" --sort-by='.lastTimestamp' | tail -30 || true
                exit 1
            fi
        else
            echo "  InstallPlan not yet created — waiting..."
        fi

        sleep ${interval}
        elapsed=$(( elapsed + interval ))
    done

    echo "ERROR: CSV did not reach 'Succeeded' within ${CSV_READY_TIMEOUT}s."
    oc get subscription "${SUBSCRIPTION_NAME}" -n "${OPERATOR_NAMESPACE}" -o yaml || true
    oc get csv -n "${OPERATOR_NAMESPACE}" -o yaml || true
    oc get events -n "${OPERATOR_NAMESPACE}" --sort-by='.lastTimestamp' | tail -30 || true
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

    echo "Waiting for secrets-store-csi-driver-operator Deployment..."
    oc rollout status deployment/secrets-store-csi-driver-operator \
        -n "${OPERATOR_NAMESPACE}" --timeout=300s

    echo "Waiting for secrets-store-csi-driver DaemonSet rollout..."
    oc rollout status daemonset/secrets-store-csi-driver \
        -n "${OPERATOR_NAMESPACE}" --timeout=300s

    echo "All secrets-store pods are ready:"
    oc get pods -n "${OPERATOR_NAMESPACE}" | grep -i secrets || oc get pods -n "${OPERATOR_NAMESPACE}"
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
