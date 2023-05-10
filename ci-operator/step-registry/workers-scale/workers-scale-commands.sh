#!/bin/sh

log(){
    echo -e "\033[1m$(date "+%d-%m-%YT%H:%M:%S") ${@}\033[0m"
}

function waitForReady() {
    echo "Wait for Ready"
    set +x
    local retries=0
    local attempts=140
    while [[ $(oc get nodes --no-headers -l node-role.kubernetes.io/worker | grep -v "NotReady\\|SchedulingDisabled" | grep worker -c) != $1 ]]; do
        log "Following nodes are currently present, waiting for desired count $1 to be met."
        log "Machinesets:"
        oc get machinesets -A
        log "Nodes:"
        oc get nodes --no-headers -l node-role.kubernetes.io/worker | cat -n
        log "Sleeping for 60 seconds"
        sleep 60
        ((retries += 1))
        if [[ "${retries}" -gt ${attempts} ]]; then
            for node in $(oc get nodes --no-headers -l node-role.kubernetes.io/worker | egrep -e "NotReady|SchedulingDisabled" | awk '{print $1}'); do
                oc describe node $node
            done

            for machine in $(oc get machines -n openshift-machine-api --no-headers | grep -v "master" | grep -v "Running" | awk '{print $1}'); do
                oc describe machine $machine -n openshift-machine-api
            done
            echo "error: all $1 nodes didn't become READY in time, failing"
            exit 1
        fi
    done
    oc get nodes --no-headers -l node-role.kubernetes.io/worker 

}

function scaleMachineSets(){
    worker_machine_sets=$(oc get --no-headers machinesets -n openshift-machine-api -l machine.openshift.io/cluster-api-machine-role!=infra,machine.openshift.io/cluster-api-machine-role!=workload | awk '{print $1}' )
    scale_num=$(echo $worker_machine_sets | wc -w | xargs)
    scale_size=$(($1/$scale_num))
    first_machine=""
    first_set=false
    set -x
    for machineset in $(echo $worker_machine_sets); do
        oc scale machinesets -n openshift-machine-api $machineset --replicas $scale_size
        if [[ "$first_set" = false ]]; then
            first_machine=$machineset
            first_set=true
        fi
    done
    if [[ $(($1%$scale_num)) != 0 ]]; then
        echo $first_machine
        oc scale machinesets -n openshift-machine-api $first_machine --replicas $(($scale_size+$(($1%$scale_num))))
    fi
}

function scaleDownMachines() {
    num_to_decrease=$(($1-$2))
    echo "num to decrease $num_to_decrease"

    for machineset in $(oc get --no-headers machinesets -n openshift-machine-api -l machine.openshift.io/cluster-api-machine-role!=infra,machine.openshift.io/cluster-api-machine-role!=workload | awk '{print $1}'); do
        echo "machine set to edit $machineset"
        machine_set_num=$(oc get machinesets -n openshift-machine-api $machineset -o jsonpath="{.spec.replicas}")
        echo "machine set scale num currently: $machine_set_num"
        if [[ $machine_set_num -eq 0 ]]; then
            echo "continue on after $machineset"
            continue
        fi
        if [[ $machine_set_num -ge $num_to_decrease ]]; then
            oc scale machinesets -n openshift-machine-api $machineset --replicas $(($machine_set_num-$num_to_decrease))
            echo "scaling down this num $(($machine_set_num-$num_to_decrease))"
            break
        else
            oc scale machinesets -n openshift-machine-api $machineset --replicas 0
            num_to_decrease=$(($num_to_decrease-$machine_set_num))
            echo "reseting num to decrease $num_to_decrease"
        fi
    done
}
current_worker_count=$(oc get nodes --no-headers -l node-role.kubernetes.io/worker | grep -v "NotReady\\|SchedulingDisabled" | wc -l | xargs)
echo "current worker count $current_worker_count"
echo "worker scale count $WORKER_COUNT"
if [[ $current_worker_count -ne $WORKER_COUNT ]]; then
    if [[ $current_worker_count -gt $WORKER_COUNT ]]; then
        scaleDownMachines $current_worker_count $WORKER_COUNT
        waitForReady $WORKER_COUNT
    else
        scaleMachineSets $WORKER_COUNT
        waitForReady $WORKER_COUNT
    fi
fi