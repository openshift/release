#!/bin/bash

set -o nounset
set -o errexit
set -o pipefail

if [ -z "${RT_ENABLED}" ] || [ "${RT_ENABLED}" != "true" ]; then
    echo "Not set RT_ENABLED to true, ignore checking"
    exit 0
fi

if [ -f "${SHARED_DIR}/kubeconfig" ] ; then
    export KUBECONFIG=${SHARED_DIR}/kubeconfig
else
    echo "ERROR: fail to get the kubeconfig file under ${SHARED_DIR}!!"
    exit 1
fi

if [ -f "${SHARED_DIR}/proxy-conf.sh" ] ; then
    source "${SHARED_DIR}/proxy-conf.sh"
fi

rets=$(oc get machineconfigs | grep realtime-worker)
echo ${rets}
if [[ ${rets} =~ "realtime-worker" ]] ; then
    mapfile -t nodes < <(oc get nodes --selector='node-role.kubernetes.io/worker' --no-headers | awk '{print $1}')
    for i in "${nodes[@]}"; do
        tmp=$(oc -n default debug node/$i -- uname -a;)
        echo ${tmp}
        if [[ ! ${tmp} =~ PREEMPT_RT ]]; then
            echo "ERROR: fail to find PREEMPT_RT kennel running !!"
            exit 1
        fi
    done
else
    echo "ERROR: Fail to get the expected kerneltype in the machineconfigs"
    exit 1
fi

echo "Check RealTime Kernel PASS!"
exit 0
