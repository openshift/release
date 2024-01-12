#!/bin/bash

set -o nounset
set -o errexit
set -o pipefail

if [ -f "${SHARED_DIR}/kubeconfig" ] ; then
  export KUBECONFIG=${SHARED_DIR}/kubeconfig
else
  echo "No KUBECONFIG found, exit now"
  exit 1
fi

if test -f "${SHARED_DIR}/proxy-conf.sh"
then
    # shellcheck disable=SC1090
    source "${SHARED_DIR}/proxy-conf.sh"
fi

ret=0


# --------------------------------
# Node Count
# --------------------------------
echo ">>>>>> Checking Outpost nodes count"

outpost_id=$(jq -r '.OutpostId' ${CLUSTER_PROFILE_DIR}/aws_outpost_info.json)
outpost_node_count=$(oc get nodes --selector='node-role.kubernetes.io/worker' --show-labels --no-headers | grep "outpost-id=${outpost_id}" | wc -l)
echo "Outpost node count: ${outpost_node_count}, expect: ${EXPECTED_OUTPOST_NODE}"

if [[ "${outpost_node_count}" != "${EXPECTED_OUTPOST_NODE}" ]]; then
  echo "--------- MACHINES ---------"
  oc get machine --selector machine.openshift.io/cluster-api-machine-type=worker -n openshift-machine-api -o yaml
  echo "--------- NODES ---------"
  oc get nodes --selector='node-role.kubernetes.io/worker' -o yaml
  echo "FAIL: Outpost nodes count"
  ret=$((ret+1))
else
  echo "PASS: Outpost nodes count"
fi

# --------------------------------
# MTU
# --------------------------------
echo ">>>>>> Checking MTU"

CLUSTER_MTU=$(oc get network.config cluster -o=jsonpath='{.status.clusterNetworkMTU}')
NETWORK_TYPE=$(oc get network.config cluster -o=jsonpath='{.status.networkType}')

echo "Cluster MTU: ${CLUSTER_MTU}"
echo "Cluster Network Type: ${NETWORK_TYPE}"
if [[ $NETWORK_TYPE == "OpenShiftSDN" ]]; then
  echo "Expected MTU: ${EXPECTED_MTU_SDN}"
  if [[ "${CLUSTER_MTU}" == "${EXPECTED_MTU_SDN}" ]]; then
    echo "PASS: Cluster MTU"
  else
    echo "FAIL: Cluster MTU"
    ret=$((ret+1))
  fi
elif [[ $NETWORK_TYPE == "OVNKubernetes" ]]; then
  echo "Expected MTU: ${EXPECTED_MTU_OVN}"
  if [[ "${CLUSTER_MTU}" == "${EXPECTED_MTU_OVN}" ]]; then
    echo "PASS: Cluster MTU"
  else
    echo "FAIL: Cluster MTU"
    ret=$((ret+1))
  fi
fi

exit $ret
