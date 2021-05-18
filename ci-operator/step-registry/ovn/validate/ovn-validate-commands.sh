#!/bin/bash
set -o errexit
set -o nounset
set -o pipefail

abortJob=false
EXPECTED_MASTER_POD_COUNT=3
EXPECTED_NODE_POD_COUNT=6

# debug... delete this line before merging...
echo "GATEWAY_MODE: ${GATEWAY_MODE}"
echo echo "KUBECONFIG: ${KUBECONFIG}"

# list and count the number of ovnkube master and node pods
oc get pods --namespace=openshift-ovn-kubernetes | grep ovnkube-master
ovnKubeMasterPodsCount="$(oc get pods --namespace=openshift-ovn-kubernetes | grep ovnkube-master | wc -l)"
oc get pods --namespace=openshift-ovn-kubernetes | grep ovnkube-node
ovnKubeNodePodsCount="$(oc get pods --namespace=openshift-ovn-kubernetes | grep ovnkube-node | wc -l)"

if [[ $ovnKubeMasterPodsCount -ne ${EXPECTED_MASTER_POD_COUNT} ]] ||
   [[ ovnKubeNodePodsCount -ne ${EXPECTED_NODE_POD_COUNT} ]]; then
  echo "Expected ${EXPECTED_MASTER_POD_COUNT} ovnkube master pods and ${EXPECTED_NODE_POD_COUNT} node pods";
  abortJob=true
fi

# scan all the ovnkube pod logs for the ovnkube command with the gateway-mode argument and validate that we
# get $EXPECTED_MASTER_POD_COUNT + $EXPECTED_MASTER_POD_COUNT matches of the $GATEWAY_MODE configured for the job
podGwModeLogs=$(oc get pods --namespace=openshift-ovn-kubernetes | egrep -v NAME | awk '{print $1}' \
                            | xargs -n1 oc logs --all-containers --namespace=openshift-ovn-kubernetes \
                            | egrep 'ovnkube .* --gateway-mode')
echo "Pod log entries matching 'ovnkube .* --gateway-mode':"
echo $podGwModeLogs
numCorrectGwModeCommands=$(echo $podGwModeLogs |  awk -F"--gateway-mode ${GATEWAY_MODE}" '{print NF-1}')

if [[ $numCorrectGwModeCommands -ne $(( $EXPECTED_MASTER_POD_COUNT + $EXPECTED_NODE_POD_COUNT )) ]]; then
  echo "Expected to find $(( $EXPECTED_MASTER_POD_COUNT + $EXPECTED_NODE_POD_COUNT )) instances of" \
       "\"--gateway-mode ${GATEWAY_MODE}\" in the ovnkube pods."
  abortJob=true
fi

if $abortJob; then
  echo "At least one OVNK validation check failed. Aborting job."
  exit 1
fi
