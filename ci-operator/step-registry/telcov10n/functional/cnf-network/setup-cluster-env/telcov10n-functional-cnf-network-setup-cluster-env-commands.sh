#!/bin/bash
set -e
set -o pipefail

echo "Checking if the job should be skipped..."
if [ -f "${SHARED_DIR}/skip.txt" ]; then
  echo "Detected skip.txt file — skipping the job"
  exit 0
fi


echo "Setup pipeline environment"
cd /eco-ci-cd/
export ANSIBLE_REMOTE_TEMP="/tmp"
ansible-playbook ./playbooks/setup-cluster-env.yml --extra-vars "release=${VERSION} dest_directory=${SHARED_DIR}"

echo "Cluster name"
cat ${SHARED_DIR}/cluster_name

echo "OCP primary nic"
cat ${SHARED_DIR}/ocp_nic

echo "OCP secondary nic"
cat ${SHARED_DIR}/secondary_nic
