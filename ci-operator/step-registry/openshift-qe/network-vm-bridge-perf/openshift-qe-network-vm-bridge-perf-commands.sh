#!/bin/bash
set -o errexit
set -o nounset
set -o pipefail
set -x


# For disconnected or otherwise unreachable environments, we want to
# have steps use an HTTP(S) proxy to reach the API server. This proxy
# configuration file should export HTTP_PROXY, HTTPS_PROXY, and NO_PROXY
# environment variables, as well as their lowercase equivalents (note
# that libcurl doesn't recognize the uppercase variables).
if test -f "${SHARED_DIR}/proxy-conf.sh"; then
  # shellcheck disable=SC1090
  source "${SHARED_DIR}/proxy-conf.sh"
fi

pushd /tmp

ES_PASSWORD=$(cat "/secret/password")
ES_USERNAME=$(cat "/secret/username")

NNCP_NAME="${BRIDGE}-${BRIDGE_PORT}"
oc apply -f - <<EOF
apiVersion: nmstate.io/v1
kind: NodeNetworkConfigurationPolicy
metadata:
  name: ${NNCP_NAME}
spec:
  desiredState:
    interfaces:
      - name: ${BRIDGE}
        description: Linux bridge with ${BRIDGE_PORT} as a port
        type: linux-bridge
        state: up
        ipv4:
          dhcp: true
          enabled: true
        bridge:
          options:
            stp:
              enabled: false
          port:
            - name: ${BRIDGE_PORT}
EOF

echo "Waiting for NNCP ${NNCP_NAME} to become Available..."
oc wait nncp/"${NNCP_NAME}" --for=condition=Available --timeout=10m
oc get nncp "${NNCP_NAME}" -o yaml

cleanup_nncp() {
  if [ "${CLEAN_UP}" != "true" ]; then
    return 0
  fi
  echo "Tearing down NNCP ${NNCP_NAME}..."
  oc apply -f - <<EOF
apiVersion: nmstate.io/v1
kind: NodeNetworkConfigurationPolicy
metadata:
  name: ${NNCP_NAME}
spec:
  desiredState:
    interfaces:
      - name: ${BRIDGE}
        type: linux-bridge
        state: absent
EOF
  oc wait nncp/"${NNCP_NAME}" --for=condition=Available --timeout=10m
  oc delete nncp/"${NNCP_NAME}" --ignore-not-found=true --wait=true
}
trap cleanup_nncp EXIT

REPO_URL="https://github.com/cloud-bulldozer/e2e-benchmarking";
LATEST_TAG=$(git ls-remote --tags https://github.com/cloud-bulldozer/e2e-benchmarking.git | awk -F'refs/tags/' '{print $2}' | grep -v '\^{}' | sort -V | tail -n1)
TAG_OPTION="--branch $(if [ "$E2E_VERSION" == "default" ]; then echo "$LATEST_TAG"; else echo "$E2E_VERSION"; fi)";
git clone $REPO_URL $TAG_OPTION --depth 1
pushd e2e-benchmarking/workloads/network-perf-v2

if [ "${CLEAN_UP}" == "true" ]; then
# Clean up resources from possible previous tests.
  oc delete ns netperf --wait=true --ignore-not-found=true
fi

#If vm mode enable, generate a new ssh key to access the VM
if [ "${VM}" == "true" ]; then
  mkdir -p ~/.ssh
  ssh-keygen -t rsa -b 4096 -N "" -f ~/.ssh/id_rsa
fi

# Only store the results from the full run versus the smoke test.
export ES_SERVER="https://$ES_USERNAME:$ES_PASSWORD@search-ocp-qe-perf-scale-test-elk-hcm7wtsqpxy7xogbu72bor4uve.us-east-1.es.amazonaws.com"

NETPERF_FILENAME="${NETPERF_FILENAME}" \
VM="${VM}" \
POD="${POD}" \
BRIDGE="${BRIDGE}" \
BRIDGE_CONFIG="${BRIDGE_CONFIG}" \
USE_VIRTCTL="${USE_VIRTCTL}" \
ALL_SCENARIOS="${ALL_SCENARIOS}" \
./run.sh
