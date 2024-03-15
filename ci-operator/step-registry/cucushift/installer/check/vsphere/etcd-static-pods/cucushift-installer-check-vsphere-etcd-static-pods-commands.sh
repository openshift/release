#!/bin/bash

set -o nounset
set -o errexit
set -o pipefail

export KUBECONFIG=${SHARED_DIR}/kubeconfig

check_etcd_static_pods() {
    local static_pods_num=0
    set -x
    master_node_name=$(oc get nodes | grep master | awk -F' ' '{print $1}')
    etcd_pods_name=$(oc get pod -n openshift-etcd | grep 'Running' | awk -F' ' '{print $1}')
    for name in $master_node_name
    do
       num=$(echo $etcd_pods_name | grep $name | wc -l)
       static_pods_num=$((static_pods_num + num))
    done
    set +x
    #The expected number is specified by env MASTER_REPLICAS
    if [ X"$static_pods_num" != X"${MASTER_REPLICAS}" ]; then
	echo "INFO: the number of etcd static pods equal to MASTER_REPLICAS. that's expected"    
        return 0
    else
	 echo "ERROR: the number of etcd static pods not equal to MASTER_REPLICAS. please check!"    
	return 1
    fi

}

if [[ -n "${MASTER_REPLICAS}" ]]; then
	check_etcd_static_pods
fi

