#!/bin/bash
set -e
set -o pipefail

echo "Setup compute-nto pipeline environment"
# cd /eco-ci-cd/
# export ANSIBLE_REMOTE_TEMP="/tmp"
# set -x
# ansible-playbook ./playbooks/setup-cluster-env.yml --extra-vars "release=${VERSION} dest_directory=${SHARED_DIR}"
# set +x

echo "${CLUSTER_NAME}" > ${SHARED_DIR}/cluster_name
echo "${VERSION}" > ${SHARED_DIR}/cluster_version

echo "Cluster name"
cat ${SHARED_DIR}/cluster_name

echo "Cluster version"
cat ${SHARED_DIR}/cluster_version

# echo "OCP primary nic"
# cat ${SHARED_DIR}/ocp_nic

# echo "OCP secondary nic"
# cat ${SHARED_DIR}/secondary_nic