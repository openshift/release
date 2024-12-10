#!/usr/bin/env bash

set -Eeuo pipefail

export OS_CLIENT_CONFIG_FILE="${SHARED_DIR}/clouds.yaml"

function wait_for_worker_machines() {
    INTERVAL=10
    CNT=180

    while [ $((CNT)) -gt 0 ]; do
        READY=false
        while read -r i
        do
            name=$(echo "${i}" | awk '{print $1}')
            status=$(echo "${i}" | awk '{print $2}')
            if [[ "${status}" == "Ready" ]]; then
                echo "Worker ${name} is ready"
                READY=true
            else
                echo "Waiting for the worker to be ready"
            fi
        done <<< "$(oc get node --no-headers -l node-role.kubernetes.io/worker | grep -v master)"

        if [[ ${READY} == "true" ]]; then
            echo "Worker is ready"
            return 0
        else
            sleep "${INTERVAL}"
            CNT=$((CNT))-1
        fi

        if [[ $((CNT)) -eq 0 ]]; then
            echo "Timed out waiting for worker to be ready"
            oc get node
            return 1
        fi
    done
}

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
SUBNET_ID=$(openstack network show "${OPENSTACK_SRIOV_NETWORK}" -f json -c subnets | jq '.subnets[0]' | sed 's/"//g')

oc_version=$(oc version -o json | jq -r '.openshiftVersion')
if [[ "${oc_version}" != *"4.9"* && "${oc_version}" != *"4.10"* && "$CONFIG_DRIVE" != "true" ]]; then
    CONFIG_DRIVE=false
else
    CONFIG_DRIVE=true
fi

echo "Downloading current MachineSet for workers"
WORKER_MACHINESET=$(oc get machinesets.machine.openshift.io -n openshift-machine-api | grep worker | awk '{print $1}')
oc get machinesets.machine.openshift.io -n openshift-machine-api "${WORKER_MACHINESET}" -o json > "${SHARED_DIR}/original-worker-machineset.json"

if [[ "${OPENSTACK_SRIOV_NETWORK}" == *"hwoffload"* ]]; then
    PROFILE="\"profile\": {\"capabilities\": \"[switchdev]\"},"
fi

cat <<EOF > "${SHARED_DIR}/sriov_patch.json"
{
  "spec": {
    "template": {
      "spec": {
        "providerSpec": {
          "value": {
            "configDrive": ${CONFIG_DRIVE},
            "ports": [
              {
                "networkID": "${NETWORK_ID}",
                "nameSuffix": "sriov",
                "fixedIPs": [
                  {
                    "subnetID": "${SUBNET_ID}"
                  }
                ],
                "tags": [
                  "sriov"
                ],
                "vnicType": "direct",
                ${PROFILE:-}
                "portSecurity": false,
                "trunk": false
              }
            ]
          }
        }
      }
    }
  }
}
EOF
echo "Merging the original worker MachineSet with the patched configuration for SR-IOV"
jq -Ss '.[0] * .[1]' "${SHARED_DIR}/original-worker-machineset.json" "${SHARED_DIR}/sriov_patch.json" > "${SHARED_DIR}/sriov-worker-machineset.json"
python -c 'import sys, yaml, json; yaml.dump(json.load(sys.stdin), sys.stdout, indent=2)' < "${SHARED_DIR}/sriov-worker-machineset.json" > "${SHARED_DIR}/sriov-worker-machineset.yaml"

echo "Apply the new MachineSet for SR-IOV workers"
oc apply -f "${SHARED_DIR}/sriov-worker-machineset.yaml"

echo "Scaling up worker to 1"
oc scale --replicas=1 machinesets.machine.openshift.io "${WORKER_MACHINESET}" -n openshift-machine-api
wait_for_worker_machines

echo "Disable mastersSchedulable since we now have a dedicated worker node"
oc patch Scheduler cluster --type=merge --patch '{ "spec": { "mastersSchedulable": false } }'
sleep 10

echo "Apply SRIOV capable label to the worker node"
WORKER_NODE=$(oc get node -o custom-columns=NAME:.metadata.name --no-headers -l node-role.kubernetes.io/worker)
oc label node "${WORKER_NODE}" feature.node.kubernetes.io/network-sriov.capable="true"
sleep 10
WORKER_NODE_LABELS=$(oc get node "${WORKER_NODE}" -o jsonpath='{.metadata.labels}')
if [[ "${WORKER_NODE_LABELS}" != *"feature.node.kubernetes.io/network-sriov.capable"* ]]; then
    echo "Failed to apply SRIOV capable label to the worker node"
    exit 1
fi

echo "${WORKER_NODE}" > "${SHARED_DIR}/sriov-worker-node"
echo "SR-IOV worker node is ready!"
