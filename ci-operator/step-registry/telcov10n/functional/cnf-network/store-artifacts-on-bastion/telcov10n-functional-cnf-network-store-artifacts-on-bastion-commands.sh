#!/bin/bash
set -e
set -o pipefail
PROJECT_DIR="/tmp"

echo "Set bastion ssh configuration"
cat $SHARED_DIR/all | grep ansible_ssh_private_key -A 100 | sed 's/ansible_ssh_private_key: //g' | sed "s/'//g" > $PROJECT_DIR/temp_ssh_key
chmod 600 $PROJECT_DIR/temp_ssh_key
BASTION_IP=$(cat ${SHARED_DIR}/bastion | grep -oP '(?<=ansible_host: ).*' | sed "s/'//g")
BASTION_USER=$(cat ${SHARED_DIR}/all | grep -oP '(?<=ansible_user: ).*'| sed "s/'//g")

echo "Store pahse 1 build id"
echo $BUILD_ID > ${SHARED_DIR}/phase1_build_id

echo "Store eco-gotests artifacts on bastion host"
echo "Run cnf-tests via ssh tunnel"
ssh -o ServerAliveInterval=60 -o ServerAliveCountMax=3 -o StrictHostKeyChecking=no $BASTION_USER@$BASTION_IP -i /tmp/temp_ssh_key "rm -rf ~/build-artifiacts; mkdir ~/build-artifiacts; cp /tmp/downstream_report/*.xml ~/build-artifiacts/"

echo "Store SHARED_DIR content on bastion host"
scp -r -o StrictHostKeyChecking=no -o UserKnownHostsFile=/dev/null -i /tmp/temp_ssh_key ${SHARED_DIR}/* $BASTION_USER@$BASTION_IP:~/build-artifiacts/
