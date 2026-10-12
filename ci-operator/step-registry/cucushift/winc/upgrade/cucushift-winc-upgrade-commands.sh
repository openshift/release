#!/bin/bash
set -o errexit
set -o nounset
set -o pipefail
set -x

function run_command() {
    local CMD="$1"
    echo "Running Command: ${CMD}"
    eval "${CMD}"
}

# Returns true if no Windows nodes are in SchedulingDisabled status.
windows_nodes_schedulable()
{
	[ "$(oc get nodes -l kubernetes.io/os=windows -o jsonpath="{range .items[*].spec.taints[*]}{.effect}:{.key}{'\n'}{end}" | grep "NoSchedule:node.kubernetes.io/unschedulable" | wc -l)" -eq 0 ]
}

# Wait for WMCO's CSV to be Successfully upgraded
oc wait csv --all --for=jsonpath='{.status.phase}'=Succeeded -n openshift-windows-machine-config-operator

# Wait for WMCO to be up and running
oc wait deployment windows-machine-config-operator -n openshift-windows-machine-config-operator --for condition=Available=True --timeout=5m

winworker_machineset_name=$(oc get machineset -n openshift-machine-api -o json | jq -r '.items[] | select(.metadata.name | test("win")).metadata.name')
winworker_machineset_replicas=$(oc get machineset -n openshift-machine-api $winworker_machineset_name -o jsonpath="{.spec.replicas}")

echo "Waiting for Windows Machines to be in Running state"
while [[ $(oc -n openshift-machine-api get machineset/${winworker_machineset_name} -o 'jsonpath={.status.readyReplicas}') != "${winworker_machineset_replicas}" ]]; do echo -n "." && sleep 10; done

echo "Waiting for Windows nodes to be Schedulable."

COUNTER=0
while [ $COUNTER -lt 900 ]
do
    if windows_nodes_schedulable; then
        echo "No Windows nodes found in ScheduledDisabled"
        break
    fi

    COUNTER=`expr $COUNTER + 20`
    echo "waiting ${COUNTER}s"
    sleep 20
done

if ! windows_nodes_schedulable; then
    echo "Some of the Windows nodes is still in ScheduledDisabled"
    run_command "oc get nodes -o wide"
    run_command "oc describe nodes -l kubernetes.io/os=Windows"
fi

# Make sure the Windows nodes get in Ready state
oc wait nodes -l kubernetes.io/os=windows --for condition=Ready=True --timeout=15m

# Wait up to 5 minutes for Windows workload to be ready
oc wait deployment win-webserver -n winc-test --for condition=Available=True --timeout=5m
