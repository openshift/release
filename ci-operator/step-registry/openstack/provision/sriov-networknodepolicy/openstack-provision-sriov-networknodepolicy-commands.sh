#!/usr/bin/env bash

set -o nounset
set -o errexit
set -o pipefail

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

if ! openstack network show "${OPENSTACK_SRIOV_NETWORK}" >/dev/null 2>&1; then
    echo "Network ${OPENSTACK_SRIOV_NETWORK} doesn't exist"
    exit 1
fi
NETWORK_ID=$(openstack network show "${OPENSTACK_SRIOV_NETWORK}" -f value -c id)

# Re-enable the webhook on 4.9 when this PR is merged and released in 4.9z:
# https://github.com/openshift/sriov-network-operator/pull/618
oc_version=$(oc version -o json | jq -r '.openshiftVersion')
if [[ "${oc_version}" == *"4.9"* ]]; then
    oc patch sriovoperatorconfig default --type=merge -n openshift-sriov-network-operator --patch '{ "spec": { "enableOperatorWebhook": false } }'
    sleep 5
fi

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
