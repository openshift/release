#!/usr/bin/env bash

set -o nounset
set -o errexit
set -o pipefail

create_default_sriov_operator_config() {
    oc apply -f - <<EOF
apiVersion: sriovnetwork.openshift.io/v1
kind: SriovOperatorConfig
metadata:
  name: default
  namespace: openshift-sriov-network-operator
spec:
  enableInjector: true
  enableOperatorWebhook: true
  logLevel: 2
EOF
}

create_sriov_networknodepolicy() {
    local name="${1}"
    local network="${2}"
    local driver="${3}"
    local is_rdma="${4}"

    if ! openstack network show "${network}" >/dev/null 2>&1; then
        openstack network show "${network}"
        echo "Network ${network} doesn't exist"
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
  isRdma: ${is_rdma}
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

# This is only needed on ocp 4.16+
# introduced https://github.com/openshift/sriov-network-operator/pull/887
# u/s https://github.com/k8snetworkplumbingwg/sriov-network-operator/pull/617
create_default_sriov_operator_config

oc_version=$(oc version -o json | jq -r '.openshiftVersion' | cut -d '.' -f1,2)

go version

echo "Waiting SRIOV components to be installed for release-${oc_version}."
git clone --branch release-${oc_version} https://github.com/openshift/sriov-network-operator /tmp/sriov-network-operator
pushd /tmp/sriov-network-operator
make deploy-wait
popd

if [[ "${OPENSTACK_SRIOV_NETWORK}" == *"mellanox"* ]]; then
    SRIOV_DEVICE_TYPE="netdevice"
    IS_RDMA="true"
else
    SRIOV_DEVICE_TYPE="vfio-pci"
    IS_RDMA="false"
fi

echo "Print SriovNetworkNodeState before creating SriovNetworkNodePolicy"
oc get SriovNetworkNodeState -n openshift-sriov-network-operator -o yaml

create_sriov_networknodepolicy "sriov1" "${OPENSTACK_SRIOV_NETWORK}" "${SRIOV_DEVICE_TYPE}" "${IS_RDMA}"

if [[ "${OPENSTACK_DPDK_NETWORK}" != "" ]]; then
    if oc get MachineConfig/99-vhostuser-bind >/dev/null 2>&1; then
        echo "vhostuser is already bound to the ${OPENSTACK_DPDK_NETWORK} network."
        exit 0
    fi
    create_sriov_networknodepolicy "dpdk1" "${OPENSTACK_DPDK_NETWORK}" "vfio-pci" "false"
fi
