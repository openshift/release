#!/bin/bash
set -o nounset
set -o errexit
set -o pipefail


if test -s "${SHARED_DIR}/proxy-conf.sh" ; then
    source "${SHARED_DIR}/proxy-conf.sh"
fi

export KUBECONFIG=${SHARED_DIR}/kubeconfig

log(){
    echo -e "\033[1m$(date "+%d-%m-%YT%H:%M:%S") " "${*}\033[0m"
}

# Verify CAPI and MAPI worker counts match
verify_worker_counts() {
    echo "Verifying CAPI and MAPI worker counts..."
    
    capi_workers=$(oc get machines.cluster.x-k8s.io -n openshift-cluster-api -l node-role.kubernetes.io/worker= --no-headers | wc -l)
    mapi_workers=$(oc get machines.machine.openshift.io -n openshift-machine-api -l machine.openshift.io/cluster-api-machine-role=worker --no-headers | wc -l)
    
    if [ "$capi_workers" -ne "$mapi_workers" ]; then
        echo "ERROR: Worker count mismatch! CAPI workers: $capi_workers, MAPI workers: $mapi_workers"
        exit 1
    fi
    
    echo "Worker counts match: CAPI=$capi_workers, MAPI=$mapi_workers"
}

# Check MachineSet conditions
check_machineset_conditions() {
    echo "Checking MachineSet conditions..."
    
    machinesets=$(oc get machinesets.machine.openshift.io -n openshift-machine-api -o name)
    
    for ms in $machinesets; do   
        # Check authoritativeAPI
        auth_api=$(oc get $ms -n openshift-machine-api -o jsonpath='{.spec.authoritativeAPI}')
        if [ "$auth_api" != "MachineAPI" ]; then
            echo "ERROR: $ms has authoritativeAPI=$auth_api (expected MachineAPI)"
            exit 1
        fi
        
        # Check paused condition
        paused_status=$(oc get "$ms" -n openshift-machine-api -o jsonpath='{.status.conditions[?(@.type=="Paused")].status}')

        if [ "$paused_status" != "False" ]; then
            echo "ERROR: $ms Paused condition is not False"
            exit 1
        fi

        # Check Synchronized condition
        sync_status=$(oc get "$ms" -n openshift-machine-api -o jsonpath='{.status.conditions[?(@.type=="Synchronized")].status}')

        if [ "$sync_status" != "True" ]; then
            echo "ERROR: $ms Synchronized condition is not True"
            exit 1
        fi
    done
    
    echo "All MachineSets meet the required conditions"
}

# Check Machine conditions
check_machine_conditions() {
    echo "Checking Machine conditions..."
    
    machines=$(oc get machines.machine.openshift.io -n openshift-machine-api -o name -l machine.openshift.io/cluster-api-machine-role=worker)
    
    for m in $machines; do
        # Check authoritativeAPI
        auth_api=$(oc get $m -n openshift-machine-api -o jsonpath='{.spec.authoritativeAPI}')
        if [ "$auth_api" != "MachineAPI" ]; then
            echo "ERROR: $m has authoritativeAPI=$auth_api (expected MachineAPI)"
            exit 1
        fi
        
        # Check paused condition
        paused_status=$(oc get "$m" -n openshift-machine-api -o jsonpath='{.status.conditions[?(@.type=="Paused")].status}')

        if [ "$paused_status" != "False" ]; then
            echo "ERROR: $m Paused condition is not False"
            exit 1
        fi

        # Check Synchronized condition
        sync_status=$(oc get "$m" -n openshift-machine-api -o jsonpath='{.status.conditions[?(@.type=="Synchronized")].status}')

        if [ "$sync_status" != "True" ]; then
            echo "ERROR: $m Synchronized condition is not True"
            exit 1
        fi
    done
    
    echo "All Machines meet the required conditions"
}

log "The clusteroperators are: "
oc get co

verify_worker_counts
check_machineset_conditions
check_machine_conditions
log "All checks passed successfully!"
