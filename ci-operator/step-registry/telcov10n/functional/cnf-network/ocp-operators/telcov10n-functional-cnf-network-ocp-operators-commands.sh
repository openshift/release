#!/bin/bash
set -e
set -o pipefail

process_inventory() {
    local directory="$1"
    local dest_file="$2"

    if [ -z "$directory" ]; then
        echo "Usage: process_inventory <directory> <dest_file>"
        return 1
    fi

    if [ ! -d "$directory" ]; then
        echo "Error: '$directory' is not a valid directory"
        return 1
    fi

    find "$directory" -type f | while IFS= read -r filename; do
        if [[ $filename == *"secretsync-vault-source-path"* ]]; then
          continue
        else
          echo "$(basename ${filename})": \'"$(cat $filename)"\'
        fi
    done > $dest_file

    echo "Processing complete. Check ${dest_file}"
}

echo "Create group_vars directory"
mkdir /eco-ci-cd/inventories/ocp-deployment/group_vars

find /var/group_variables/common/ -mindepth 1 -type d | while read -r dir; do
    echo "Process group inventory file: ${dir}"
    process_inventory $dir /eco-ci-cd/inventories/ocp-deployment/group_vars/"$(basename ${dir})"
done

find /var/group_variables/${CLUSTER_NAME}/ -mindepth 1 -type d | while read -r dir; do
    echo "Process group inventory file: ${dir}"
    process_inventory $dir /eco-ci-cd/inventories/ocp-deployment/group_vars/"$(basename ${dir})"
done

echo "Create host_vars directory"
mkdir /eco-ci-cd/inventories/ocp-deployment/host_vars

find /var/host_variables/${CLUSTER_NAME}/ -mindepth 1 -type d | while read -r dir; do
    echo "Process group inventory file: ${dir}"
    process_inventory $dir /eco-ci-cd/inventories/ocp-deployment/host_vars/"$(basename ${dir})"
done

# ansible-playbook ./playbooks/deploy-ocp-hybrid-multinode.yml -i ./inventories/ocp-deployment/deploy-ocp-hybrid-multinode.yml --extra-vars "release=${VERSION} cluster_name=${CLUSTER_NAME}"

cd /eco-ci-cd
echo ${USER}
echo ${CLUSTER_NAME}
echo ${VERSION}
ansible-playbook ./playbooks/deploy-ocp-operators.yaml -i ./inventories/ocp-deployment/deploy-ocp-hybrid-multinode.yml \
    --extra-vars 'kubeconfig="/home/${USER}/project/generated/${CLUSTER_NAME}/auth/kubeconfig" version="${VERSION}" \ 
    operators=[{"name":"sriov-network-operator","catalog":"redhat-operators-stage","nsname":"openshift-sriov-network-operator","deploy_default_config":"true"},\
    {"name":"ptp-operator","catalog":"redhat-operators-stage","nsname":"openshift-ptp","ns_labels":{"workload.openshift.io/allowed":"management","name":"openshift-ptp"}},\
    {"name":"kubernetes-nmstate-operator","catalog":"redhat-operators","nsname":"openshift-nmstate","deploy_default_config":"true"},\
    {"name":"sriov-fec","catalog":"certified-operators","nsname":"vran-acceleration-operators","channel":"stable"},\
    {"name":"metallb-operator","catalog":"redhat-operators-stage","nsname":"metallb-system","channel":"stable","og_spec":{},"deploy_default_config":"true"}]'