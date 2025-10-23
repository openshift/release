#!/bin/bash

env >> ${SHARED_DIR}/orig_env.sh

# set enviornment based variables if they exist
if [ -f "${KUBECONFIG}" ]; then
    masters=0
    infra=0
    workers=0
    all=0
    master_type=""
    infra_type=""
    worker_type=""

    # Using from e2e-benchmarking
    for node in $(oc get nodes --ignore-not-found --no-headers -o custom-columns=:.metadata.name || true); do
        labels=$(oc get node "$node" --no-headers -o jsonpath='{.metadata.labels}')
        if [[ $labels == *"node-role.kubernetes.io/master"* ]]; then
            masters=$((masters + 1))
            master_type=$(oc get node "$node" -o jsonpath='{.metadata.labels.beta\.kubernetes\.io/instance-type}')
            taints=$(oc get node "$node" -o jsonpath='{.spec.taints}')

            if [[ $labels == *"node-role.kubernetes.io/worker"* && $taints == "" ]]; then
                workers=$((workers + 1))
            fi
        elif [[ $labels == *"node-role.kubernetes.io/infra"* ]]; then
            infra=$((infra + 1))
            infra_type=$(oc get node "$node" -o jsonpath='{.metadata.labels.beta\.kubernetes\.io/instance-type}')
        elif [[ $labels == *"node-role.kubernetes.io/worker"* ]]; then
            workers=$((workers + 1))
            worker_type=$(oc get node "$node" -o jsonpath='{.metadata.labels.beta\.kubernetes\.io/instance-type}')
        fi
        all=$((all + 1))
    done
    export master_type
    export infra_type
    worker_count=$workers
    export worker_count

    master_count=$masters
    export master_count

    infra_count=$infra
    export infra_count

    total_node_count=$all
    export total_node_count
    node_instance_type=$worker_type
    export node_instance_type
    network_plugins=$(oc get network.config/cluster -o jsonpath='{.status.networkType}')
    export network_plugins
    cloud_infrastructure=$(oc get infrastructure cluster -o jsonpath='{.status.platformStatus.type}')
    export cloud_infrastructure
    cluster_type=""
    if [ "$cloud_infrastructure" = "AWS" ]; then
        cluster_type=$(oc get infrastructure cluster -o jsonpath='{.status.platformStatus.aws.resourceTags[?(@.key=="red-hat-clustertype")].value}') || echo "Cluster Install Failed"
    fi
    if [ -z "$cluster_type" ]; then
        cluster_type="self-managed"
    fi
    cloud_type=$cluster_type
    export cloud_type
    export version=${VERSION:=$(oc version -o json | jq -r '.openshiftVersion')}
fi

# put to file location and will ger from orion_envs

env

declare -p | grep -v "declare -a" | grep -v "BASH" | grep -v "FUNCNAME" | grep -v "LINENO" | grep -v "PPID" | grep -v "SHELLOPTS" | grep -v "UID" | grep -v "PROW" >> local_variables.sh

grep -vxFf ${SHARED_DIR}/orig_env.sh ${SHARED_DIR}/local_variables.sh >> ${SHARED_DIR}/orion.sh

tr '\n' ',' < ${SHARED_DIR}/orion.sh > ${SHARED_DIR}/orion_env.sh

cp ${SHARED_DIR}/orion_env.sh ${ARTIFACT_DIR}/orion_env.sh