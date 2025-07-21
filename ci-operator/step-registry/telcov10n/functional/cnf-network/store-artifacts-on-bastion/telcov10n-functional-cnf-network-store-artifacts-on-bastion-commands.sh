#!/bin/bash
set -e
set -o pipefail
PROJECT_DIR="/tmp"

echo "Checking if the job should be skipped..."
if [ -f "${SHARED_DIR}/skip.txt" ]; then
  echo "Detected skip.txt file — skipping the job"
  exit 0
fi

echo "Set bastion ssh configuration"
grep ansible_ssh_private_key -A 100 "${SHARED_DIR}/all" \
  | sed -e 's/ansible_ssh_private_key: //g' -e "s/'//g" \
  > "${PROJECT_DIR}/temp_ssh_key"
chmod 600 "${PROJECT_DIR}"/temp_ssh_key
BASTION_IP=$(grep -oP '(?<=ansible_host: ).*' "${SHARED_DIR}/bastion" | sed "s/'//g")
BASTION_USER=$(grep -oP '(?<=ansible_user: ).*' "${SHARED_DIR}/all" | sed "s/'//g")

echo "Store pahse 1 build id"
echo "${BUILD_ID}" > "${SHARED_DIR}"/phase1_build_id

echo "Store eco-gotests artifacts on bastion host"
echo "Run cnf-tests via ssh tunnel"
ssh -o ServerAliveInterval=60 \
    -o ServerAliveCountMax=3 \
    -o StrictHostKeyChecking=no \
    "${BASTION_USER}@${BASTION_IP}" \
    -i /tmp/temp_ssh_key "rm -rf ~/build-artifiacts; mkdir ~/build-artifiacts; cp /tmp/downstream_report/*.xml ~/build-artifiacts/"

echo "Store SHARED_DIR content on bastion host"
scp -r -o StrictHostKeyChecking=no \
    -o UserKnownHostsFile=/dev/null \
    -i /tmp/temp_ssh_key \
    "${SHARED_DIR}"/* "${BASTION_USER}@${BASTION_IP}":~/build-artifiacts/
