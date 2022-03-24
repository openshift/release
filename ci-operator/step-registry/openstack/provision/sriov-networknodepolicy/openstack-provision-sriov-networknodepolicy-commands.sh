#!/usr/bin/env bash

set -o nounset
set -o errexit
set -o pipefail

create_sriov_networknodepolicy() {
    local name="${1}"
    local network="${2}"
    local driver="${3}"

    if ! openstack network show "${network}" >/dev/null 2>&1; then
        echo "Network ${network} doesn't exist"
        exit 1
    fi
    net_id=$(openstack network show "${network}" -f value -c id)

    SRIOV_NETWORKNODEPOLICY=$(
        oc create -f - -o jsonpath='{.metadata.name}' <<EOF
apiVersion: sriovnetwork.openshift.io/v1
kind: SriovNetworkNodePolicy
metadata:
  name: ${name}
  namespace: openshift-sriov-network-operator
spec:
  deviceType: ${driver} 
  nicSelector:
    netFilter: openstack/NetworkID:${net_id}
  nodeSelector:
    feature.node.kubernetes.io/network-sriov.capable: 'true'
  numVfs: 1
  priority: 99
  resourceName: ${name}
EOF
    )
    echo "Created \"$SRIOV_NETWORKNODEPOLICY\" SriovNetworkNodePolicy"
}

if ! test -f "${SHARED_DIR}/sriov-worker-node"; then
  echo "${SHARED_DIR}/sriov-worker-node file not found, no worker node for SR-IOV was deployed"
  exit 1
fi

export OS_CLIENT_CONFIG_FILE="${SHARED_DIR}/clouds.yaml"

# For disconnected or otherwise unreachable environments, we want to
# have steps use an HTTP(S) proxy to reach the API server. This proxy
# configuration file should export HTTP_PROXY, HTTPS_PROXY, and NO_PROXY
# environment variables, as well as their lowercase equivalents (note
# that libcurl doesn't recognize the uppercase variables).
if test -f "${SHARED_DIR}/proxy-conf.sh"
then
	# shellcheck disable=SC1090
	source "${SHARED_DIR}/proxy-conf.sh"
fi

create_sriov_networknodepolicy "sriov1" "${OPENSTACK_SRIOV_NETWORK}" "vfio-pci"

if [[ "${OPENSTACK_DPDK_NETWORK}" != "" ]]; then
    if oc get MachineConfig/99-vhostuser-bind >/dev/null 2>&1; then
        echo "vhostuser is already bound to the ${OPENSTACK_DPDK_NETWORK} network."
        exit 0
    fi
    create_sriov_networknodepolicy "dpdk1" "${OPENSTACK_DPDK_NETWORK}" "vfio-pci"
fi
