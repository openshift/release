#!/bin/bash
set -o nounset
set -o errexit
set -o pipefail

export KUBECONFIG=${SHARED_DIR}/kubeconfig

# When ACM is not installed, we can use the OCP version to determine the ACM version for must-gather
declare -A OCP_TO_ACM=(
  ["4.14"]="2.9"
  ["4.15"]="2.10"
  ["4.16"]="2.11"
  ["4.17"]="2.12"
  ["4.18"]="2.13"
  ["4.19"]="2.14"
  ["4.20"]="2.15"
  ["4.21"]="2.16"
  ["4.22"]="2.17"
)

OCP_VERSION=$(oc get clusterversion version -o jsonpath='{.status.desired.version}' | cut -d'.' -f1,2)
echo "OpenShift version: ${OCP_VERSION}"

ACM_VERSION=$(oc get multiclusterhub -A -o jsonpath='{.items[0].status.currentVersion}' 2>/dev/null | cut -d'.' -f1,2 || true)
if [[ -z "${ACM_VERSION}" ]]; then
  ACM_VERSION="${OCP_TO_ACM[${OCP_VERSION}]:-}"
  if [[ -z "${ACM_VERSION}" ]]; then
    echo "WARNING: No ACM version mapping for OCP ${OCP_VERSION_FOR_ACM}, falling back to MCE must-gather"
  fi
fi

HC_ARGS=""
HC_NAMESPACE=$(oc get hostedclusters.hypershift.openshift.io -A -o jsonpath='{.items[0].metadata.namespace}' 2>/dev/null || true)
HC_NAME=$(oc get hostedclusters.hypershift.openshift.io -A -o jsonpath='{.items[0].metadata.name}' 2>/dev/null || true)
if [[ -n "${HC_NAMESPACE}" && -n "${HC_NAME}" ]]; then
  echo "Found HostedCluster ${HC_NAMESPACE}/${HC_NAME}"
  HC_ARGS="hosted-cluster-namespace=${HC_NAMESPACE} hosted-cluster-name=${HC_NAME}"
fi

# For pre-release images, we need to use the pre-release registry.
# Pulling from the pre-release registry requires credentials.
# The credentials for acm-d are present in acm-d-mce-quay-credentials secret.
echo "Using ACM must-gather image with ACM_VERSION=${ACM_VERSION}"
MUST_GATHER_IMAGE="registry.redhat.io/rhacm2/acm-must-gather-rhel9:v${ACM_VERSION}"
if ! oc image info "${MUST_GATHER_IMAGE}" --filter-by-os="linux/amd64" &>/dev/null; then
  echo "Image ${MUST_GATHER_IMAGE} not found, falling back to pre-release registry"
  MUST_GATHER_IMAGE="quay.io:443/acm-d/acm-must-gather-rhel9:${ACM_VERSION}-dev"
fi

# shellcheck disable=SC2086
oc adm must-gather \
  --image="${MUST_GATHER_IMAGE}" \
  /usr/bin/gather ${HC_ARGS} \
  --dest-dir="${ARTIFACT_DIR}"
