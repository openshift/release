#!/bin/bash
set -euxo pipefail; shopt -s inherit_errexit

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

  # Add quay.io:443 auth to cluster pull secret so the must-gather pod can pull the dev image
  if [[ -f /etc/acm-d-mce-quay-pull-credentials/acm_d_mce_quay_username ]]; then
    # Merge quay.io:443 auth into the cluster pull secret
    typeset tmpPullSecret
    tmpPullSecret=$(mktemp)
    oc extract secret/pull-secret -n openshift-config --to=- --keys=.dockerconfigjson > "${tmpPullSecret}"
    # Build auth token and merge into pull secret (xtrace disabled to protect credentials)
    ( set +x
      typeset quayUsername quayPassword quayAuth
      quayUsername=$(cat /etc/acm-d-mce-quay-pull-credentials/acm_d_mce_quay_username)
      quayPassword=$(cat /etc/acm-d-mce-quay-pull-credentials/acm_d_mce_quay_pullsecret)
      quayAuth=$(echo -n "${quayUsername}:${quayPassword}" | base64 -w 0)
      # Use python3 (available in RHEL-based cli image) instead of jq (not available)
      _QUAY_AUTH="${quayAuth}" python3 -c '
import json, os, sys
with open(sys.argv[1]) as f:
    ps = json.load(f)
ps.setdefault("auths", {})["quay.io:443"] = {"auth": os.environ["_QUAY_AUTH"], "email": ""}
with open(sys.argv[1] + ".tmp", "w") as f:
    json.dump(ps, f)
' "${tmpPullSecret}"
      mv "${tmpPullSecret}.tmp" "${tmpPullSecret}"
    true )
    oc set data secret/pull-secret -n openshift-config --from-file=.dockerconfigjson="${tmpPullSecret}"
    rm -f "${tmpPullSecret}"
    # Wait for the MCO to propagate the updated pull secret to nodes
    sleep 60
    oc wait mcp master worker --for condition=updated --timeout=15m || true
  else
    : "WARNING: Credentials not available at /etc/acm-d-mce-quay-pull-credentials/, pre-release image pull may fail"
  fi
fi

# shellcheck disable=SC2086
oc adm must-gather \
  --image="${MUST_GATHER_IMAGE}" \
  /usr/bin/gather ${HC_ARGS} \
  --dest-dir="${ARTIFACT_DIR}"
