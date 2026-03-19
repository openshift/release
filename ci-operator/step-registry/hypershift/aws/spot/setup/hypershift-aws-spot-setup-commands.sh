#!/bin/bash

set -o nounset
set -o errexit
set -o pipefail
set -o xtrace

# This step patches the HostedCluster with the SQS queue URL for the
# AWS Node Termination Handler, annotates the existing NodePool to
# enable spot, and waits for CAPI resources to be reconciled.

CLUSTER_NAME=$(cat "${SHARED_DIR}/cluster-name")
QUEUE_URL=$(cat "${SHARED_DIR}/spot_sqs_queue_url")
HC_NAMESPACE="clusters"

echo "Patching HostedCluster ${CLUSTER_NAME} with terminationHandlerQueueURL"
oc patch hostedcluster "${CLUSTER_NAME}" -n "${HC_NAMESPACE}" --type=merge -p "{
  \"spec\": {
    \"platform\": {
      \"aws\": {
        \"terminationHandlerQueueURL\": \"${QUEUE_URL}\"
      }
    }
  }
}"

# Annotate the existing NodePool to enable spot
NP_NAME=$(oc get nodepool -n "${HC_NAMESPACE}" -o jsonpath='{.items[0].metadata.name}')
echo "Annotating NodePool ${NP_NAME} with enable-spot"
oc annotate nodepool "${NP_NAME}" -n "${HC_NAMESPACE}" hypershift.openshift.io/enable-spot="true"

# Save nodepool name for verify step
echo "${NP_NAME}" > "${SHARED_DIR}/spot_nodepool_name"

# Copy guest kubeconfig for verify step
if [[ -f "${SHARED_DIR}/nested_kubeconfig" ]]; then
  cp "${SHARED_DIR}/nested_kubeconfig" "${SHARED_DIR}/guest_kubeconfig"
fi

# HCP namespace follows the convention: <hc-namespace>-<cluster-name>
HCP_NAMESPACE="${HC_NAMESPACE}-${CLUSTER_NAME}"
echo "HCP namespace: ${HCP_NAMESPACE}"

# Wait for spot MachineHealthCheck to be created (indicates controller reconciled the spot NodePool)
SPOT_MHC_NAME="${NP_NAME}-spot"
echo "Waiting for spot MachineHealthCheck ${SPOT_MHC_NAME} in namespace ${HCP_NAMESPACE}"
timeout 10m bash -c "
  until oc get machinehealthcheck ${SPOT_MHC_NAME} -n ${HCP_NAMESPACE} 2>/dev/null; do
    echo \"\$(date) Waiting for spot MachineHealthCheck...\"
    sleep 10
  done
"
echo "Spot MachineHealthCheck created"

# Wait for aws-node-termination-handler deployment to exist
echo "Waiting for aws-node-termination-handler deployment in namespace ${HCP_NAMESPACE}"
timeout 10m bash -c "
  until oc get deployment aws-node-termination-handler -n ${HCP_NAMESPACE} 2>/dev/null; do
    echo \"\$(date) Waiting for NTH deployment...\"
    sleep 10
  done
"
echo "NTH deployment created"

echo "Spot setup complete"
