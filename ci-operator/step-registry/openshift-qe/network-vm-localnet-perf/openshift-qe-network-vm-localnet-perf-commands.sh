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

# Disable tracing due to password handling
[[ $- == *x* ]] && WAS_TRACING=true || WAS_TRACING=false
set +x
ES_PASSWORD=$(cat "/secret/password")
ES_USERNAME=$(cat "/secret/username")
$WAS_TRACING && set -x

echo "Using LOCALNET_PORT=${LOCALNET_PORT} LOCALNET_BRIDGE=${LOCALNET_BRIDGE} LOCALNET=${LOCALNET}"

NNCP_NAME="${LOCALNET_PORT}-ovs-underlay"
# Rolling apply: 100% maxUnavailable made every worker reconfigure OVS/OVN at
# once, and NMState then rolled back on ping-probe failure. Default 50% is
# enough once apply succeeds. Keep a long wait so a slow batch cannot hide
# behind MaxUnavailableLimitReached.
NNCP_WAIT_TIMEOUT="20m"

dump_nncp() {
  echo "=== Nodes ==="
  oc get nodes -o wide || true
  echo "=== ${LOCALNET_PORT} and default routes in NodeNetworkState ==="
  oc get nns -o custom-columns=NODE:.metadata.name --no-headers | while read -r node; do
    iface_state="$(oc get nns "${node}" -o jsonpath="{range .status.currentState.interfaces[?(@.name=='${LOCALNET_PORT}')]}name={.name} type={.type} state={.state} ipv4={.ipv4.enabled} ipv6={.ipv6.enabled} addrs={.ipv4.address}{end}" 2>/dev/null || true)"
    if [ -z "${iface_state}" ]; then
      echo "${node}: ${LOCALNET_PORT} NOT FOUND"
    else
      echo "${node}: ${iface_state}"
    fi
    oc get nns "${node}" -o jsonpath="{range .status.currentState.routes.running[?(@.destination=='0.0.0.0/0')]}${node} default via {.next-hop-address} dev {.next-hop-interface} metric={.metric}{\"\\n\"}{end}" 2>/dev/null || true
  done
  echo "=== NNCP ${NNCP_NAME} ==="
  oc get nncp "${NNCP_NAME}" -o yaml || true
  echo "=== NNCEs ==="
  oc get nnce -o wide || true
  oc get nnce -o yaml || true
  echo "=== nmstate-handler logs ==="
  oc logs -n openshift-nmstate -l component=kubernetes-nmstate-handler --tail=200 --prefix=true || true
}

echo "=== Cluster state before NNCP ==="
dump_nncp

oc apply -f - <<EOF
apiVersion: nmstate.io/v1
kind: NodeNetworkConfigurationPolicy
metadata:
  name: ${NNCP_NAME}
spec:
  nodeSelector:
    node-role.kubernetes.io/worker: ""
  desiredState:
    interfaces:
      - name: ${LOCALNET_BRIDGE}
        description: "OVS Bridge dedicated to ${LOCALNET_PORT} for CUDN Localnets"
        type: ovs-bridge
        state: up
        ipv4:
          enabled: false
          dhcp: false
        ipv6:
          enabled: false
          dhcp: false
        bridge:
          allow-extra-patch-ports: true
          options:
            stp: false
          port:
            - name: ${LOCALNET_PORT}
    ovn:
      bridge-mappings:
        - localnet: ${LOCALNET}
          bridge: ${LOCALNET_BRIDGE}
          state: present
EOF

echo "Waiting for NNCP ${NNCP_NAME} to become Available..."
if ! oc wait nncp/"${NNCP_NAME}" --for=condition=Available --timeout="${NNCP_WAIT_TIMEOUT}"; then
  dump_nncp
  exit 1
fi
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
  nodeSelector:
    node-role.kubernetes.io/worker: ""
  desiredState:
    interfaces:
      - name: ${LOCALNET_BRIDGE}
        type: ovs-bridge
        state: absent
    ovn:
      bridge-mappings:
        - localnet: ${LOCALNET}
          bridge: ${LOCALNET_BRIDGE}
          state: absent
EOF
  if ! oc wait nncp/"${NNCP_NAME}" --for=condition=Available --timeout="${NNCP_WAIT_TIMEOUT}"; then
    dump_nncp
    return 1
  fi
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

# Disable tracing due to password handling
set +x
export ES_SERVER="https://$ES_USERNAME:$ES_PASSWORD@search-ocp-qe-perf-scale-test-elk-hcm7wtsqpxy7xogbu72bor4uve.us-east-1.es.amazonaws.com"
$WAS_TRACING && set -x

NETPERF_FILENAME="${NETPERF_FILENAME}" \
VM="${VM}" \
POD="${POD}" \
LOCALNET="${LOCALNET}" \
LOCALNET_CONFIG="${LOCALNET_CONFIG}" \
USE_VIRTCTL="${USE_VIRTCTL}" \
ALL_SCENARIOS="${ALL_SCENARIOS}" \
./run.sh
