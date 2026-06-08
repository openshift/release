#!/bin/bash
#
# Provision a new ROSA cluster and register it in the pool.
#
# This is a manual helper script, not a Prow step. Run it locally to
# add clusters to the standby pool.
#
# Prerequisites:
#   - ocm CLI logged into the target environment (staging)
#   - rosa CLI configured with correct AWS credentials
#   - oc CLI with kubeconfig for the pool host cluster (app.ci)
#
# Usage:
#   ./rosa-pool-provision.sh --name rosa-pool-01 --region us-east-1 --version 4.22
#   ./rosa-pool-provision.sh --name rosa-pool-02 --region us-east-1 --version 4.22
#

set -o nounset
set -o errexit
set -o pipefail

log(){
    echo -e "\033[1m$(date "+%d-%m-%YT%H:%M:%S") " "${*}\033[0m" >&2
}

# Defaults
POOL_NAME=""
REGION="us-east-1"
VERSION="4.22"
POOL_NAMESPACE="rosa-pool"
POOL_TYPE="classic-sts"
CHANNEL_GROUP="stable"
COMPUTE_NODES=2
COMPUTE_MACHINE_TYPE="m5.xlarge"
BILLING_ACCOUNT=""
POOL_HOST_KUBECONFIG="${POOL_HOST_KUBECONFIG:-}"

usage() {
    echo "Usage: $0 --name <cluster-name> [options]"
    echo ""
    echo "Options:"
    echo "  --name          Cluster name (required, e.g. rosa-pool-01)"
    echo "  --region        AWS region (default: us-east-1)"
    echo "  --version       OCP version prefix (default: 4.22)"
    echo "  --channel       Channel group (default: stable)"
    echo "  --nodes         Compute nodes (default: 2)"
    echo "  --machine-type  Compute machine type (default: m5.xlarge)"
    echo "  --billing       AWS billing account ID"
    echo "  --pool-kubeconfig  Kubeconfig for pool host cluster"
    echo "  --register-only Skip cluster creation, just register existing cluster"
    exit 1
}

REGISTER_ONLY=false

while [[ $# -gt 0 ]]; do
    case "$1" in
        --name) POOL_NAME="$2"; shift 2 ;;
        --region) REGION="$2"; shift 2 ;;
        --version) VERSION="$2"; shift 2 ;;
        --channel) CHANNEL_GROUP="$2"; shift 2 ;;
        --nodes) COMPUTE_NODES="$2"; shift 2 ;;
        --machine-type) COMPUTE_MACHINE_TYPE="$2"; shift 2 ;;
        --billing) BILLING_ACCOUNT="$2"; shift 2 ;;
        --pool-kubeconfig) POOL_HOST_KUBECONFIG="$2"; shift 2 ;;
        --register-only) REGISTER_ONLY=true; shift ;;
        *) usage ;;
    esac
done

if [[ -z "${POOL_NAME}" ]]; then
    echo "ERROR: --name is required"
    usage
fi

pool_oc() {
    if [[ -n "${POOL_HOST_KUBECONFIG}" ]]; then
        oc --kubeconfig="${POOL_HOST_KUBECONFIG}" "$@"
    else
        oc "$@"
    fi
}

if [[ "${REGISTER_ONLY}" == "false" ]]; then
    # Resolve the latest version matching the prefix
    FULL_VERSION=$(rosa list versions --channel-group "${CHANNEL_GROUP}" -o json 2>/dev/null | \
        jq -r '[.[] | select(.raw_id | startswith("'"${VERSION}"'")) | select(.enabled == true)] | sort_by(.raw_id) | last | .raw_id')

    if [[ -z "${FULL_VERSION}" || "${FULL_VERSION}" == "null" ]]; then
        log "ERROR: No available version matching ${VERSION} in channel group ${CHANNEL_GROUP}"
        exit 1
    fi

    log "Provisioning pool cluster: ${POOL_NAME}"
    log "  Region: ${REGION}"
    log "  Version: ${FULL_VERSION}"
    log "  Nodes: ${COMPUTE_NODES} x ${COMPUTE_MACHINE_TYPE}"

    # Build rosa create command
    ROSA_ARGS=(
        "create" "cluster"
        "--cluster-name" "${POOL_NAME}"
        "--sts"
        "--mode" "auto"
        "--region" "${REGION}"
        "--version" "${FULL_VERSION}"
        "--channel-group" "${CHANNEL_GROUP}"
        "--compute-nodes" "${COMPUTE_NODES}"
        "--compute-machine-type" "${COMPUTE_MACHINE_TYPE}"
        "--tags" "rosa-pool:true,pool-type:${POOL_TYPE}"
        "-y"
    )

    if [[ -n "${BILLING_ACCOUNT}" ]]; then
        ROSA_ARGS+=("--billing-account" "${BILLING_ACCOUNT}")
    fi

    rosa "${ROSA_ARGS[@]}"

    log "Waiting for cluster to be ready..."
    rosa wait cluster --cluster "${POOL_NAME}" --timeout 3600
fi

# Get cluster details from OCM
CLUSTER_JSON=$(ocm list clusters --parameter search="name = '${POOL_NAME}'" --json 2>/dev/null || true)
CLUSTER_ID=$(echo "${CLUSTER_JSON}" | jq -r '.items[0].id // empty')

if [[ -z "${CLUSTER_ID}" ]]; then
    log "ERROR: Cluster ${POOL_NAME} not found in OCM"
    exit 1
fi

API_URL=$(echo "${CLUSTER_JSON}" | jq -r '.items[0].api.url // empty')
ACTUAL_VERSION=$(echo "${CLUSTER_JSON}" | jq -r '.items[0].openshift_version // empty')
OCM_ENV=$(ocm config get url | sed 's|https://api\.||;s|\..*||')

log "Cluster ready: ${CLUSTER_ID}"
log "  API: ${API_URL}"
log "  Version: ${ACTUAL_VERSION}"

# Register in pool
log "Registering cluster in pool namespace ${POOL_NAMESPACE}..."

VERSION_LABEL=$(echo "${ACTUAL_VERSION}" | cut -d. -f1,2)

cat <<EOF | pool_oc apply -n "${POOL_NAMESPACE}" -f -
apiVersion: v1
kind: ConfigMap
metadata:
  name: ${POOL_NAME}
  namespace: ${POOL_NAMESPACE}
  labels:
    rosa-pool/managed: "true"
    rosa-pool/type: ${POOL_TYPE}
    rosa-pool/region: ${REGION}
    rosa-pool/version: "${VERSION_LABEL}"
    rosa-pool/status: available
  annotations:
    rosa-pool/holder: ""
    rosa-pool/build-id: ""
    rosa-pool/acquired-at: ""
    rosa-pool/released-at: ""
    rosa-pool/registered-at: "$(date -u +%Y-%m-%dT%H:%M:%SZ)"
data:
  cluster-id: "${CLUSTER_ID}"
  cluster-name: "${POOL_NAME}"
  api-url: "${API_URL}"
  region: "${REGION}"
  version: "${ACTUAL_VERSION}"
  ocm-env: "${OCM_ENV}"
EOF

log "Pool cluster ${POOL_NAME} registered successfully"
log ""
log "To verify: pool_oc get configmap ${POOL_NAME} -n ${POOL_NAMESPACE} -o yaml"
