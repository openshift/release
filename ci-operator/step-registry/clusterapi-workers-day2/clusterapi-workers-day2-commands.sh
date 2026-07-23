#!/bin/bash

log(){
    echo -e "\033[1m$(date "+%d-%m-%YT%H:%M:%S") " "${*}\033[0m"
}

function waitForMigrationCompleted() {
    echo "Wait for migration complete"
    sleep 60
    local retries=0
    local attempts=40
    local finish=0
    local flag=1
    local machineStatus=""
    local machinesetStatus=""

    while [[ "${finish}" -eq 0 ]]; do
        for machine in `oc get machines.machine.openshift.io -n openshift-machine-api -l machine.openshift.io/cluster-api-machine-role=worker -o='jsonpath={.items[*].metadata.name}'`; do   
            local expectedMachineStatus="MachineAPIFalseTrue"
            echo "get machine $machine status"
            machineSpec=$(oc get machines.machine.openshift.io $machine -n openshift-machine-api -o='jsonpath={.spec.authoritativeAPI}')
            if [[ $machineSpec == "ClusterAPI" ]]; then
                expectedMachineStatus="ClusterAPITrueTrue"
            fi
            machineStatus=$(oc get machines.machine.openshift.io $machine -n openshift-machine-api -o='jsonpath={.status.authoritativeAPI}{.status.conditions[?(@.type=="Paused")].status}{.status.conditions[?(@.type=="Synchronized")].status}')	
            if [[ $machineStatus != "$expectedMachineStatus" ]]; then
                echo "machine $machine spec $machineSpec status $machineStatus"
                flag=0
                break
            fi
        done
        if [[ "${flag}" -eq 1 ]]; then
            for machineset in `oc get machinesets.machine.openshift.io -n openshift-machine-api -o='jsonpath={.items[*].metadata.name}'`; do   
                local expectedMachinesetStatus="MachineAPIFalseTrue"
                echo "get machineset $machineset status"
                machinesetSpec=$(oc get machinesets.machine.openshift.io $machineset -n openshift-machine-api -o='jsonpath={.spec.authoritativeAPI}')
                if [[ $machinesetSpec == "ClusterAPI" ]]; then
                    expectedMachinesetStatus="ClusterAPITrueTrue"
                fi
                machinesetStatus=$(oc get machinesets.machine.openshift.io $machineset -n openshift-machine-api -o='jsonpath={.status.authoritativeAPI}{.status.conditions[?(@.type=="Paused")].status}{.status.conditions[?(@.type=="Synchronized")].status}')	
                if [[ $machinesetStatus != "$expectedMachinesetStatus" ]]; then
                    echo "machineset $machineset spec $machinesetSpec status $machinesetStatus"
                    flag=0
                    break
                fi
            done
        fi
        if [[ "${flag}" -eq 0 ]]; then
            log "Migration has not completed ... retries $retries"
            if [[ "${retries}" -gt ${attempts} ]]; then    
                echo "error: Wait migration failed, failing"
                exit 1
            fi
            log "Sleeping for 60 seconds"
            sleep 60
            flag=1
            ((retries += 1))
        else
            finish=1
        fi
    done
    log "Migration completed! retries $retries"
}

function patchWorkerMachines() {
    for machine in `oc get machines.machine.openshift.io -n openshift-machine-api -l machine.openshift.io/cluster-api-machine-role=worker -o='jsonpath={.items[*].metadata.name}'`; do   
        echo "patch machine $machine"
        local patchMachineLabels='{"spec":{"authoritativeAPI":"ClusterAPI"}}'
        oc patch machines.machine.openshift.io $machine -p "$patchMachineLabels" --type=merge -n openshift-machine-api
        echo "machine $machine patched $patchMachineLabels"
        if [[ $MACHINESET_AUTHORITATIVEAPI_IN_MACHINESET != "$MACHINE_AUTHORITATIVEAPI_IN_MACHINESET" ]]; then
        #The two values ​​are not equal, means expecting mixed configuration of MachineAPI and ClusterAPI, so change only one worker to ClusterAPI, and the other workers remain MachineAPI.
            break
        fi
    done
    log "All worker machines are patched!"
}

function patchWorkerMachineSets() {
    for machineset in `oc get machinesets.machine.openshift.io -n openshift-machine-api -o='jsonpath={.items[*].metadata.name}'`; do   
        echo "patch machineset $machineset"
        local patchMachineSetLabels='{"spec":{"authoritativeAPI":"'$MACHINESET_AUTHORITATIVEAPI_IN_MACHINESET'","template":{"spec":{"authoritativeAPI":"'$MACHINE_AUTHORITATIVEAPI_IN_MACHINESET'"}}}}'
        oc patch machinesets.machine.openshift.io $machineset -p "$patchMachineSetLabels" --type=merge -n openshift-machine-api
        echo "machineset $machineset patched $patchMachineSetLabels"
    done
    log "All worker machinesets are patched!"
}

if [ -f "${SHARED_DIR}/kubeconfig" ] ; then
    export KUBECONFIG=${SHARED_DIR}/kubeconfig
fi

if [ -f "${SHARED_DIR}/proxy-conf.sh" ] ; then
    source "${SHARED_DIR}/proxy-conf.sh"
fi

log "Before migrate, the machines, machineset and cos are: "
oc get machines.machine.openshift.io -n openshift-machine-api -oyaml
oc get machinesets.machine.openshift.io -n openshift-machine-api -oyaml
oc get co
patchWorkerMachines
patchWorkerMachineSets
waitForMigrationCompleted
log "After migrate, the machines, machinesets and cos are: "
oc get machines.machine.openshift.io -n openshift-machine-api -oyaml
oc get machinesets.machine.openshift.io -n openshift-machine-api -oyaml
oc get co
log "worker machines and machinesets migrate successfully"
