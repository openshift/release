#!/bin/bash

set -o nounset
set -o errexit
set -o pipefail
set -o xtrace

# This step patches the HostedCluster with the SQS queue URL for the
# AWS Node Termination Handler, creates a spot NodePool using the
# annotation-based enablement, and waits for CAPI resources to be
# reconciled.

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

# Get details from existing NodePool to use for the spot NodePool
RELEASE_IMAGE=$(oc get nodepool -n "${HC_NAMESPACE}" -o jsonpath='{.items[0].spec.release.image}')
INSTANCE_PROFILE=$(oc get nodepool -n "${HC_NAMESPACE}" -o jsonpath='{.items[0].spec.platform.aws.instanceProfile}')

# Get subnet - try .id first, fall back to .filters
SUBNET_ID=$(oc get nodepool -n "${HC_NAMESPACE}" -o jsonpath='{.items[0].spec.platform.aws.subnet.id}' 2>/dev/null || true)
if [[ -z "${SUBNET_ID}" ]]; then
  SUBNET_ID=$(oc get nodepool -n "${HC_NAMESPACE}" -o jsonpath='{.items[0].spec.platform.aws.subnet.filters[0].values[0]}' 2>/dev/null || true)
fi

SPOT_NP_NAME="${CLUSTER_NAME}-spot"
echo "Creating spot NodePool: ${SPOT_NP_NAME}"

cat <<EOF | oc apply -f -
apiVersion: hypershift.openshift.io/v1beta1
kind: NodePool
metadata:
  name: ${SPOT_NP_NAME}
  namespace: ${HC_NAMESPACE}
  annotations:
    hypershift.openshift.io/enable-spot: "true"
spec:
  clusterName: ${CLUSTER_NAME}
  replicas: 1
  management:
    autoRepair: true
    upgradeType: Replace
  platform:
    type: AWS
    aws:
      instanceType: m5.xlarge
      instanceProfile: ${INSTANCE_PROFILE}
      subnet:
        id: ${SUBNET_ID}
      rootVolume:
        size: 120
        type: gp3
  release:
    image: ${RELEASE_IMAGE}
EOF

# Save spot NodePool name for verify step
echo "${SPOT_NP_NAME}" > "${SHARED_DIR}/spot_nodepool_name"

# Copy guest kubeconfig for verify step
if [[ -f "${SHARED_DIR}/nested_kubeconfig" ]]; then
  cp "${SHARED_DIR}/nested_kubeconfig" "${SHARED_DIR}/guest_kubeconfig"
fi

# Get HCP namespace (wait for it to be populated in status)
HCP_NAMESPACE=""
echo "Waiting for controlPlaneNamespace to be set on HostedCluster status"
timeout 5m bash -c "
  while true; do
    NS=\$(oc get hostedcluster ${CLUSTER_NAME} -n ${HC_NAMESPACE} -o jsonpath='{.status.controlPlaneNamespace}' 2>/dev/null)
    if [[ -n \"\${NS}\" ]]; then
      echo \"\${NS}\"
      break
    fi
    echo \"\$(date) controlPlaneNamespace not set yet...\"
    sleep 10
  done
"
HCP_NAMESPACE=$(oc get hostedcluster "${CLUSTER_NAME}" -n "${HC_NAMESPACE}" -o jsonpath='{.status.controlPlaneNamespace}')
if [[ -z "${HCP_NAMESPACE}" ]]; then
  HCP_NAMESPACE="${HC_NAMESPACE}-${CLUSTER_NAME}"
  echo "WARNING: controlPlaneNamespace still empty, using fallback: ${HCP_NAMESPACE}"
fi
echo "HCP namespace: ${HCP_NAMESPACE}"

# Wait for spot MachineHealthCheck to be created (indicates controller reconciled the spot NodePool)
echo "Waiting for spot MachineHealthCheck ${SPOT_NP_NAME}-spot in namespace ${HCP_NAMESPACE}"
timeout 10m bash -c "
  until oc get machinehealthcheck ${SPOT_NP_NAME}-spot -n ${HCP_NAMESPACE} 2>/dev/null; do
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
