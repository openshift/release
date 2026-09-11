#!/bin/bash

set -o nounset
set -o errexit
set -o pipefail

if [[ "${CLUSTER_PROFILE_NAME:-}" != "nutanix-qe-gpu" ]]; then
  echo "Job profile is not nutanix-qe-gpu, skip this step"
  exit 0
fi

check_result=0

NUTANIX_AUTH_PATH=${CLUSTER_PROFILE_DIR}/secrets.sh
declare prism_central_host
declare prism_central_port
declare prism_central_username
declare prism_central_password
declare gpu_name
declare gpu_device_id
# shellcheck source=/dev/null
source "${NUTANIX_AUTH_PATH}"

machineset_name=$(oc get machineset -o=jsonpath="{.items[0].metadata.name}" -n openshift-machine-api)
machineset_day2_gpu_name=$machineset_name"-day2-gpu"
machineset_day2_gpu_replicas=1
CONFIG="${SHARED_DIR}/$machineset_day2_gpu_name"
oc get machineset "$machineset_name" -oyaml -n openshift-machine-api >"${CONFIG}"
PATCH="${SHARED_DIR}/machineset-day2-gpu.yaml"
cat >"${PATCH}" <<EOF
metadata:
  name: $machineset_day2_gpu_name
spec:
  replicas: $machineset_day2_gpu_replicas
  selector:
    matchLabels:
      machine.openshift.io/cluster-api-machineset: $machineset_day2_gpu_name
  template:
    metadata:
      labels:
        machine.openshift.io/cluster-api-machineset: $machineset_day2_gpu_name
    spec:
      providerSpec:
        value:
          gpus:
            - type: Name
              name: "$gpu_name"
            - type: DeviceID
              deviceID: $gpu_device_id
EOF
yq-go m -x -i "${CONFIG}" "${PATCH}"

oc create -f "${CONFIG}"

# Wait 30 minutes for nodes to be ready
loops=0
max_loops=30
sleep_seconds=60
while true; do
  if [ "$(oc get machineset "$machineset_day2_gpu_name" -o=jsonpath="{.status.readyReplicas}" -n openshift-machine-api)" == "$machineset_day2_gpu_replicas" ]; then
    echo "machineset $machineset_day2_gpu_name is READY"
    break
  fi
  if [ "$loops" -ge "$max_loops" ]; then
    echo "Timeout, machineset $machineset_day2_gpu_name is not READY"
    exit 1
  fi
  echo "machineset $machineset_day2_gpu_name is not READY yet, wait $sleep_seconds seconds"
  loops=$((loops + 1))
  sleep $sleep_seconds
done
pc_url="https://${prism_central_host}:${prism_central_port}"
api_ep="${pc_url}/api/nutanix/v3/vms/list"
un="${prism_central_username}"
pw="${prism_central_password}"
function check_gpus() {
  data="{
        \"filter\":\"vm_name==$node\"
    }"
  node_json=$(curl -ks -u "${un}":"${pw}" -X POST "${api_ep}" -H "Content-Type: application/json" -d @- <<<"${data}")
  gpu_list_length=$(echo "${node_json}" | jq -r '.entities[].status.resources.gpu_list | length')
  if [[ $gpu_list_length == 2 ]]; then
    echo "Pass: passed to check node gpu"
  else
    echo "Fail: failed to check node gpu"
    check_result=$((check_result + 1))
  fi
}

IFS=' ' read -r -a worker_nodes_list <<<"$(oc get machine -n openshift-machine-api -l machine.openshift.io/cluster-api-machineset="$machineset_day2_gpu_name" -ojson | jq -r '.items[].metadata.name' | xargs)"
for node in "${worker_nodes_list[@]}"; do
  check_gpus "$node"
done

# Restore
oc delete machineset "$machineset_day2_gpu_name" -n openshift-machine-api

exit "${check_result}"
