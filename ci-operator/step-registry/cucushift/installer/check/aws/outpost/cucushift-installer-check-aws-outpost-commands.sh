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

# save for debugging
oc get machinesets -n openshift-machine-api -o json > ${ARTIFACT_DIR}/machinesets.json
oc get machine -n openshift-machine-api -o json > ${ARTIFACT_DIR}/machine.json
oc get nodes -o json > ${ARTIFACT_DIR}/nodes.json

# --------------------------------
# Node Count
# --------------------------------
echo ">>>>>> Checking Outpost nodes count"

outpost_id=$(jq -r '.OutpostId' ${CLUSTER_PROFILE_DIR}/aws_outpost_info.json)
outpost_node_count=$(oc get nodes --selector='node-role.kubernetes.io/outposts' --show-labels --no-headers | grep "outpost-id=${outpost_id}" | wc -l)
echo "Outpost node count: ${outpost_node_count}, expect: ${EXPECTED_OUTPOST_NODE}"

if [[ "${outpost_node_count}" != "${EXPECTED_OUTPOST_NODE}" ]]; then
  echo "FAIL: Outpost nodes count"
  ret=$((ret+1))
else
  echo "PASS: Outpost nodes count"
fi

# --------------------------------
# Public/Internal IP
# --------------------------------
edge_node_day2_machineset_name=$(head -n 1 ${SHARED_DIR}/edge_node_day2_machineset_name)

MACHINES=$(oc get machine -n openshift-machine-api -ojson | jq -r --arg n "$edge_node_day2_machineset_name" '.items[] | select(.metadata.labels."machine.openshift.io/cluster-api-machineset"==$n) | .metadata.name')
for machine in $MACHINES;
do
  instance_id=$(oc get machines -n openshift-machine-api ${machine} -o json | jq -r '.status.providerStatus.instanceId')
  external_dns=$(oc get machine -n openshift-machine-api ${machine} -o json | jq -r '.status.addresses[] | select(.type=="ExternalDNS") | .address')
  internal_dns=$(oc get machine -n openshift-machine-api ${machine} -o json | jq -r '.status.addresses[] | select(.type=="InternalDNS") | .address')

  machine_info="instance_id:[${instance_id}], external_dns:[${external_dns}], internal_dns:[${internal_dns}]"

  echo "MACHINE: ${machine}: ${machine_info}"
  
  # Checking
  if [[ ${EDGE_NODE_WORKER_ASSIGN_PUBLIC_IP} == "yes" ]] && [[ ${external_dns} == ec2* ]]; then
    echo "PASS: machine public ip assignment: ${machine}"
  elif [[ ${EDGE_NODE_WORKER_ASSIGN_PUBLIC_IP} == "no" ]] && ([[ "${external_dns}" == "" ]] || [[ "${external_dns}" == "null" ]]); then
    echo "PASS: machine public ip assignment: ${machine}"
  else
    echo "FAIL: machine public ip assignment: ${machine}"
    ret=$((ret+1))
  fi
done

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
