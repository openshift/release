#!/bin/bash

log(){
    echo -e "\033[1m$(date "+%d-%m-%YT%H:%M:%S") " "${*}\033[0m"
}

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

        # Approve CSRs if the desired node count > 250
        # https://issues.redhat.com/browse/OCPBUGS-47508
        if [[ $1 -gt 250 ]]; then
            csrApprove
        fi
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

function scaleMachineSets(){
    worker_machine_sets=$(oc get --no-headers machinesets.m -n openshift-machine-api -l machine.openshift.io/cluster-api-machine-role!=infra,machine.openshift.io/cluster-api-machine-role!=workload -o name | grep -v rhel )
    scale_num=$(echo $worker_machine_sets | wc -w | xargs)
    scale_size=$(($1/$scale_num))
    first_machine=""
    first_set=false
    set -x
    for machineset in $(echo $worker_machine_sets); do
        oc scale -n openshift-machine-api $machineset --replicas $scale_size
        if [[ "$first_set" = false ]]; then
            first_machine=$machineset
            first_set=true
        fi
    done
    if [[ $(($1%$scale_num)) != 0 ]]; then
        echo $first_machine
        oc scale -n openshift-machine-api $first_machine --replicas $(($scale_size+$(($1%$scale_num))))
    fi
}

function csrApprove() {
    log "Bulk Approve CSR"
    oc get csr | awk '/Pending/ && $1 !~ /^z/ {print $1}' | xargs -P 0 -I {} oc adm certificate approve {}
    log "Bulk Approved CSRs"
}

function scaleDownMachines() {
    num_to_decrease=$(($1-$2))
    echo "num to decrease $num_to_decrease"

    for machineset in $(oc get --no-headers machinesets.m -n openshift-machine-api -l machine.openshift.io/cluster-api-machine-role!=infra,machine.openshift.io/cluster-api-machine-role!=workload -o name | grep -v rhel); do
        echo "machine set to edit $machineset"
        machine_set_num=$(oc get $machineset -n openshift-machine-api -o jsonpath="{.spec.replicas}")
        echo "machine set scale num currently: $machine_set_num"
        if [[ $machine_set_num -eq 0 ]]; then
            echo "continue on after $machineset"
            continue
        fi
        if [[ $machine_set_num -ge $num_to_decrease ]]; then
            oc scale $machineset -n openshift-machine-api --replicas $(($machine_set_num-$num_to_decrease))
            echo "scaling down this num $(($machine_set_num-$num_to_decrease))"
            break
        else
            oc scale -n openshift-machine-api $machineset --replicas 0
            num_to_decrease=$(($num_to_decrease-$machine_set_num))
            echo "reseting num to decrease $num_to_decrease"
        fi
    done
}
current_worker_count=$(oc get nodes --no-headers -l "node-role.kubernetes.io/worker" --output jsonpath="{.items[?(@.status.conditions[-1].type=='Ready')].status.conditions[-1].type}" | wc -w | xargs)
echo "current worker count $current_worker_count"
echo "worker scale count $WORKER_REPLICA_COUNT"

worker_count_num=$(($WORKER_REPLICA_COUNT))
if [[ $worker_count_num -gt 0 ]]; then 
    if [[ $current_worker_count -ne $worker_count_num ]]; then
        if [[ $current_worker_count -gt $worker_count_num ]]; then
            scaleDownMachines $current_worker_count $worker_count_num
            waitForReady $worker_count_num
        else
            scaleMachineSets $worker_count_num
            waitForReady $worker_count_num
        fi
    fi
fi
