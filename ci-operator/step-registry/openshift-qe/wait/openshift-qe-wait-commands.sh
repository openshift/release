#!/bin/bash
sleep ${CLUSTER_DURATION} & wait

# Copied from workers-scale/workers-scale-commands.sh
log(){
    echo -e "\033[1m$(date "+%d-%m-%YT%H:%M:%S") " "${*}\033[0m"
}

# Copied from workers-scale/workers-scale-commands.sh
function waitForReady() {
    echo "Wait for Ready"
    set +x
    local retries=0
    local attempts=140
    while [[ $(oc get nodes --no-headers -l node-role.kubernetes.io/worker,node-role.kubernetes.io/infra!= --output jsonpath="{.items[?(@.status.conditions[-1].type=='Ready')].status.conditions[-1].status}" | tr ' ' '\n' | grep -c "True") != "$1" ]]; do
        log "Following nodes are currently present, waiting for desired count $1 to be met."
        log "Machinesets:"
        oc get machinesets.m -A
        log "Nodes:"
        oc get nodes --no-headers -l node-role.kubernetes.io/worker | cat -n
        log "Sleeping for 60 seconds"
        sleep 60
        ((retries += 1))
        if [[ "${retries}" -gt ${attempts} ]]; then
            for node in $(oc get nodes --no-headers -l node-role.kubernetes.io/worker --output jsonpath="{.items[?(@.status.conditions[-1].type=='Ready')].metadata.name}"); do
                oc describe node $node
            done
            for machine in $(oc get machine.m  -n openshift-machine-api -l machine.openshift.io/cluster-api-machine-type=worker  --output jsonpath="{.items[?(@.status.phase!='Running')].metadata.name}"); do
                oc describe machine.m $machine -n openshift-machine-api
            done
            echo "error: all $1 nodes didn't become READY in time, failing"
            exit 1
        fi
    done
    oc get nodes --no-headers -l node-role.kubernetes.io/worker 
}

echo "Reached timeout. Scaling machinesets down to 1 replica"
worker_machine_sets=$(oc get --no-headers machinesets.m -n openshift-machine-api -l machine.openshift.io/cluster-api-machine-role!=infra,machine.openshift.io/cluster-api-machine-role!=workload -o name | grep -v rhel )
first_machine=""
first_set=false
set -x
for machineset in $(echo $worker_machine_sets); do
    oc scale -n openshift-machine-api $machineset --replicas 1
    if [[ "$first_set" = false ]]; then
        first_machine=$machineset
        first_set=true
    fi
done
# Expect 4 nodes, one per machineset x 4 AZs
waitForReady 4
