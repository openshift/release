#!/bin/bash
set -e
set -o pipefail

PROJECT_DIR="/tmp"

echo "Checking if the job should be skipped..."
if [ -f "${SHARED_DIR}/skip.txt" ]; then
  echo "Detected skip.txt file — skipping the job"
  exit 0
fi

echo "Set CLUSTER_NAME env var"
if [[ -f "${SHARED_DIR}/cluster_name" ]]; then
    CLUSTER_NAME=$(cat "${SHARED_DIR}/cluster_name")
fi
export CLUSTER_NAME=${CLUSTER_NAME}
echo "CLUSTER_NAME=${CLUSTER_NAME}"

echo "Set bastion SSH configuration"
cat /var/group_variables/common/all/ansible_ssh_private_key > "${PROJECT_DIR}/temp_ssh_key"
chmod 600 "${PROJECT_DIR}/temp_ssh_key"
BASTION_IP=$(cat /var/host_variables/"${CLUSTER_NAME}"/bastion/ansible_host)
BASTION_USER=$(cat /var/group_variables/common/all/ansible_user)

echo "Run MetalLB deploy playbook"
cd /eco-ci-cd
ansible-playbook ./playbooks/cnf/deploy-run-metallb-tests-script.yaml \
    -i ./inventories/cnf/run-tests.yaml \
    --extra-vars "kubeconfig=/home/telcov10n/project/generated/${CLUSTER_NAME}/auth/kubeconfig \
    metallb_repo=${METALLB_REPO} \
    frr_image=${FRR_IMAGE} \
    ipv4_service_range=${IPV4_SERVICE_RANGE} \
    ipv6_service_range=${IPV6_SERVICE_RANGE}"

echo "Run MetalLB e2e tests via SSH"
ssh -o ServerAliveInterval=60 -o ServerAliveCountMax=3 -o StrictHostKeyChecking=no \
    "${BASTION_USER}@${BASTION_IP}" -i "${PROJECT_DIR}/temp_ssh_key" \
    "sudo /tmp/metallb/metallb-tests-run.sh || true"

echo "Gather JUnit report from bastion"
mkdir -p "${ARTIFACT_DIR}/junit_metallb"
scp -o StrictHostKeyChecking=no -o UserKnownHostsFile=/dev/null \
    -i "${PROJECT_DIR}/temp_ssh_key" \
    "${BASTION_USER}@${BASTION_IP}":/tmp/metallbreport/junit-report.xml \
    "${ARTIFACT_DIR}/junit_metallb/junit-report.xml"

rm -f "${PROJECT_DIR}/temp_ssh_key"
