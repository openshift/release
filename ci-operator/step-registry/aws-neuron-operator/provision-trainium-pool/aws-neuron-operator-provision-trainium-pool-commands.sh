#!/bin/bash
set -o nounset
set -o errexit
set -o pipefail

echo "Creating Trainium machine pool..."

CLUSTER_ID=$(cat "${SHARED_DIR}/cluster-id")
ROSA_TOKEN=$(cat "${CLUSTER_PROFILE_DIR}/ocm-token")
OCM_LOGIN_ENV=${OCM_LOGIN_ENV:-production}

rosa login --env "${OCM_LOGIN_ENV}" --token "${ROSA_TOKEN}"

MP_NAME="trainium-pool"
MP_TYPE="${MP2_MACHINE_TYPE:-trn1.2xlarge}"
MP_REPLICAS="${MP2_REPLICAS:-2}"
MP_LABELS="${MP2_LABELS:-workload=neuron-training}"

echo "Creating machine pool: ${MP_NAME}"
echo "  Instance Type: ${MP_TYPE}"
echo "  Replicas: ${MP_REPLICAS}"
echo "  Labels: ${MP_LABELS}"

rosa create machinepool \
  --cluster="${CLUSTER_ID}" \
  --name="${MP_NAME}" \
  --instance-type="${MP_TYPE}" \
  --replicas="${MP_REPLICAS}" \
  --labels="${MP_LABELS}" \
  --enable-autoscaling=false

echo "Waiting for machine pool to be ready..."
timeout=900
start_time=$(date +%s)

while true; do
  state=$(rosa describe machinepool --cluster="${CLUSTER_ID}" --machinepool="${MP_NAME}" -o json | jq -r '.status.current_replicas' || echo "0")
  
  if [ "${state}" == "${MP_REPLICAS}" ]; then
    echo "Machine pool ${MP_NAME} is ready with ${state} replicas"
    break
  fi
  
  current_time=$(date +%s)
  elapsed=$((current_time - start_time))
  
  if [ ${elapsed} -ge ${timeout} ]; then
    echo "ERROR: Timeout waiting for machine pool to be ready"
    exit 1
  fi
  
  echo "Waiting for machine pool... (${state}/${MP_REPLICAS} replicas ready)"
  sleep 30
done

echo "Trainium machine pool created successfully"
