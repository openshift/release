#!/bin/bash

set -o nounset
set -o errexit
set -o pipefail


if [ -f "${SHARED_DIR}/kubeconfig" ] ; then
    export KUBECONFIG=${SHARED_DIR}/kubeconfig
else
    echo "Error: kubeconfig was not found, exit now"
    exit 1
fi

if test -f "${SHARED_DIR}/proxy-conf.sh"
then
    # shellcheck disable=SC1090
    source "${SHARED_DIR}/proxy-conf.sh"
fi

machineset=$(oc get machineset.machine.openshift.io -n openshift-machine-api --no-headers -n openshift-machine-api --no-headers | head -n 1 | awk '{print $1}')
old_machine_count=$(oc get machineset.machine.openshift.io -n openshift-machine-api --no-headers -n openshift-machine-api --no-headers | head -n 1 | awk '{print $2}')
new_machine_count=$((old_machine_count+1))

# scale up
echo "Scale up: set replica of ${machineset} to ${new_machine_count}"
oc scale --replicas=${new_machine_count} machineset ${machineset} -n openshift-machine-api

echo "Waiting for machines get ready"
oc wait --all=true machineset.machine.openshift.io/${machineset} -n openshift-machine-api --for=jsonpath='{.status.readyReplicas}'=${new_machine_count} --timeout=10m
oc wait --all=true machineset.machine.openshift.io/${machineset} -n openshift-machine-api --for=jsonpath='{.status.availableReplicas}'=${new_machine_count} --timeout=10m
oc wait --all=true machineset.machine.openshift.io/${machineset} -n openshift-machine-api --for=jsonpath='{.status.replicas}'=${new_machine_count} --timeout=10m


echo "Waiting for nodes get ready"
# this syntax is supported by oc 4.16+
oc wait --all=true node --for=jsonpath='{.status.conditions[?(@.type=="Ready")].status}'=True --timeout=10m

worker_count=$(oc get machine.machine.openshift.io -n openshift-machine-api --no-headers | grep worker | wc -l)
node_count=$(oc get node --no-headers | grep worker  | wc -l)
if [[ "${worker_count}" != "${node_count}" ]]; then
    echo "Error: Failed to scsale up node via machine API."
    oc get machineset.machine.openshift.io -n openshift-machine-api -ojson > ${ARTIFACT_DIR}/machineset.json
    oc get machine.machine.openshift.io -n openshift-machine-api -ojson > ${ARTIFACT_DIR}/machine.json
    oc get node -ojson > ${ARTIFACT_DIR}/node.json
else
    echo "PASS: Scale up node via machine API succeeded."
fi

echo "Removing nodes, scale down: set replica of ${machineset} to ${old_machine_count}"
oc scale --replicas=${old_machine_count} machineset ${machineset} -n openshift-machine-api

# If run the following "oc wait" command immediately after "oc scale", it always (almost) fails (timeout), even if the node is ready
# so waiting for 2 mins to make sure status is up to date, and we will get a correct status by running "oc wait"
# usually, the node could be ready within 10min after "oc scale"
# (this is a kind of workaround, not trying to extend the waiting time)

# machine.machine.openshift.io/yunjiang-07416-79lwf-master-0 condition met
# machine.machine.openshift.io/yunjiang-07416-79lwf-master-1 condition met
# machine.machine.openshift.io/yunjiang-07416-79lwf-master-2 condition met
# timed out waiting for the condition on machines/yunjiang-07416-79lwf-worker-us-east-2a-c8ngz
# timed out waiting for the condition on machines/yunjiang-07416-79lwf-worker-us-east-2a-kcg4w
# timed out waiting for the condition on machines/yunjiang-07416-79lwf-worker-us-east-2a-tvxl2
# timed out waiting for the condition on machines/yunjiang-07416-79lwf-worker-us-east-2b-wng7g
# timed out waiting for the condition on machines/yunjiang-07416-79lwf-worker-us-east-2c-2cz98

sleep 120

oc wait --all=true machine.machine.openshift.io -n openshift-machine-api --for=jsonpath='{.status.phase}'=Running --timeout=10m
oc wait --all=true node --for=jsonpath='{.status.conditions[?(@.type=="Ready")].status}'=True --timeout=10m
