#!/usr/bin/env bash

set -o nounset
set -o errexit
set -o pipefail

if ! test -f "${SHARED_DIR}/sriov-worker-node"; then
  echo "${SHARED_DIR}/sriov-worker-node file not found, no worker node for SR-IOV was deployed"
  exit 1
fi
#WORKER_NODE=$(cat "${SHARED_DIR}/sriov-worker-node")

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

if ! openstack network show "${OPENSTACK_SRIOV_NETWORK}" >/dev/null 2>&1; then
    echo "Network ${OPENSTACK_SRIOV_NETWORK} doesn't exist"
    exit 1
fi
NETWORK_ID=$(openstack network show "${OPENSTACK_SRIOV_NETWORK}" -f value -c id)

# Workaround for 4.9, the VF type is not supported in the built-in device list.
# A change was made to 4.10 to allow VF.
# Disabling the webhook allows the use of the VF.
# This has been an issue since 4.7.
# oc patch sriovoperatorconfig default --type=merge -n openshift-sriov-network-operator --patch '{ "spec": { "enableOperatorWebhook": false } }'

SRIOV_NETWORKNODEPOLICY=$(
    oc create -f - -o jsonpath='{.metadata.name}' <<EOF
apiVersion: sriovnetwork.openshift.io/v1
kind: SriovNetworkNodePolicy
metadata:
  name: sriov1
  namespace: openshift-sriov-network-operator
spec:
  deviceType: vfio-pci
  nicSelector:
    netFilter: openstack/NetworkID:${NETWORK_ID}
  nodeSelector:
    feature.node.kubernetes.io/network-sriov.capable: 'true'
  numVfs: 1
  priority: 99
  resourceName: sriov1
EOF
)
echo "Created \"$SRIOV_NETWORKNODEPOLICY\" SriovNetworkNodePolicy"


# wait until we see the interfaces:
# oc get sriovnetworknodestate ${WORKER_NODE} -n openshift-sriov-network-operator -o jsonpath='{.spec.interfaces}'
