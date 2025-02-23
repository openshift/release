#!/bin/bash

log(){
    echo -e "\033[1m$(date "+%d-%m-%YT%H:%M:%S") " "${*}\033[0m"
}

function waitForCPMSUpdateCompleted() {
    echo "Wait for controlplanemachineset update completed"
    set +x
    sleep 60
    local retries=0
    local attempts=50
    local desiredReplicas readyReplicas currentReplicas updatedReplicas
    desiredReplicas="$(oc get controlplanemachineset/cluster -o=jsonpath=\{.spec.replicas\} -n openshift-machine-api)"
    readyReplicas="$(oc get controlplanemachineset/cluster -o=jsonpath=\{.status.readyReplicas\} -n openshift-machine-api)"
    currentReplicas="$(oc get controlplanemachineset/cluster -o=jsonpath=\{.status.replicas\} -n openshift-machine-api)"
    updatedReplicas="$(oc get controlplanemachineset/cluster -o=jsonpath=\{.status.updatedReplicas\} -n openshift-machine-api)"
   
    while [[ ! ("$desiredReplicas" == "$currentReplicas" && "$desiredReplicas" == "$readyReplicas" && "$desiredReplicas" == "$updatedReplicas") ]]; do
        log "The Update is still ongoing ... retries $retries, desiredReplicas is $desiredReplicas,currentReplicas is $currentReplicas,readyReplicas is $readyReplicas,updatedReplicas is $updatedReplicas."
        if [[ "${retries}" -gt ${attempts} ]]; then    
            echo "error: Wait Update failed, failing"
            exit 1
        fi
        log "Sleeping for 60 seconds"
        sleep 60
        ((retries += 1))
        desiredReplicas="$(oc get controlplanemachineset/cluster -o=jsonpath=\{.spec.replicas\} -n openshift-machine-api)"
        readyReplicas="$(oc get controlplanemachineset/cluster -o=jsonpath=\{.status.readyReplicas\} -n openshift-machine-api)"
        currentReplicas="$(oc get controlplanemachineset/cluster -o=jsonpath=\{.status.replicas\} -n openshift-machine-api)"
        updatedReplicas="$(oc get controlplanemachineset/cluster -o=jsonpath=\{.status.updatedReplicas\} -n openshift-machine-api)"
    done
    log "The Update is completed! desiredReplicas is $desiredReplicas, retries $retries"

}

function waitForClusterStable() {
    echo "Wait for cluster stable"
    set +x
    sleep 120
    local retries=0
    local attempts=20
    local authenticationState etcdState kubeapiserverState openshiftapiserverState
    authenticationState="$(oc get clusteroperator/authentication -o='jsonpath={.status.conditions[?(@.type=="Available")].status}{.status.conditions[?(@.type=="Progressing")].status}{.status.conditions[?(@.type=="Degraded")].status}')"	
	etcdState="$(oc get clusteroperator/etcd -o='jsonpath={.status.conditions[?(@.type=="Available")].status}{.status.conditions[?(@.type=="Progressing")].status}{.status.conditions[?(@.type=="Degraded")].status}')"	
	kubeapiserverState="$(oc get clusteroperator/kube-apiserver -o='jsonpath={.status.conditions[?(@.type=="Available")].status}{.status.conditions[?(@.type=="Progressing")].status}{.status.conditions[?(@.type=="Degraded")].status}')"	
	openshiftapiserverState="$(oc get clusteroperator/openshift-apiserver -o='jsonpath={.status.conditions[?(@.type=="Available")].status}{.status.conditions[?(@.type=="Progressing")].status}{.status.conditions[?(@.type=="Degraded")].status}')"
    while [[ ! ($authenticationState == "TrueFalseFalse" && $etcdState == "TrueFalseFalse" && $kubeapiserverState == "TrueFalseFalse" && $openshiftapiserverState == "TrueFalseFalse") ]]; do
        log "The co is not ready ... retries $retries, authenticationState is $authenticationState,etcdState is $etcdState,kubeapiserverState is $kubeapiserverState,openshiftapiserverState is $openshiftapiserverState."
        if [[ "${retries}" -gt ${attempts} ]]; then    
            echo "error: Wait co failed, failing"
            exit 1
        fi
        log "Sleeping for 120 seconds"
        sleep 120
        ((retries += 1))
        authenticationState=$(oc get clusteroperator/authentication -o='jsonpath={.status.conditions[?(@.type=="Available")].status}{.status.conditions[?(@.type=="Progressing")].status}{.status.conditions[?(@.type=="Degraded")].status}')	
	    etcdState=$(oc get clusteroperator/etcd -o='jsonpath={.status.conditions[?(@.type=="Available")].status}{.status.conditions[?(@.type=="Progressing")].status}{.status.conditions[?(@.type=="Degraded")].status}')	
	    kubeapiserverState=$(oc get clusteroperator/kube-apiserver -o='jsonpath={.status.conditions[?(@.type=="Available")].status}{.status.conditions[?(@.type=="Progressing")].status}{.status.conditions[?(@.type=="Degraded")].status}')	
	    openshiftapiserverState=$(oc get clusteroperator/openshift-apiserver -o='jsonpath={.status.conditions[?(@.type=="Available")].status}{.status.conditions[?(@.type=="Progressing")].status}{.status.conditions[?(@.type=="Degraded")].status}')
  
    done
    log "The co is ready! retries $retries"
}

function updateMastersMachineNamePrefix(){
    local patchMachineNamePrefix='{"spec":{"machineNamePrefix":"'"$MACHINE_NAME_PREFIX"'"}}'
    oc patch controlplanemachineset/cluster -p "$patchMachineNamePrefix" --type=merge -n openshift-machine-api 
}

function patchMasterMachines() {
    for machine in `oc get machines.machine.openshift.io -n openshift-machine-api -l machine.openshift.io/cluster-api-machine-role=master -o='jsonpath={.items[*].metadata.name}'`; do   
        echo "patch machine $machine"
        local patchMachineLabels='{"spec":{"providerSpec":{"value":{"metadata":{"labels":{"test":"test"}}}}}}'
        oc patch machines.machine.openshift.io $machine -p "$patchMachineLabels" --type=merge -n openshift-machine-api
        waitForCPMSUpdateCompleted
        waitForClusterStable
        echo "After patch $machine, the machines are: "
        oc get machines.machine.openshift.io -n openshift-machine-api
        echo "After patch $machine, the cos are: "
        oc get co
        echo "After patch $machine, the nodes are: "
        oc get node
    done
    log "All master machines are patched!"

}

log "Before update, the machines are: "
oc get machines.machine.openshift.io -n openshift-machine-api
updateMastersMachineNamePrefix
patchMasterMachines
log "After update, the machines, co and nodes are: "
oc get machines.machine.openshift.io -n openshift-machine-api
oc get co
oc get node
log "master machine names update successfully"
