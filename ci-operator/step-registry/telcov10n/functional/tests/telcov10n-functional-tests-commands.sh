#!/bin/bash

set -e
set -o pipefail

# Fix user IDs in a container
~/fix_uid.sh

SSH_KEY_PATH=/var/run/kni-qe-41-ssh-key/ssh-key
SSH_KEY=~/key
BASTION_IP_ADDR="$(cat /var/run/bastion-ip-addr/address)"

# Check connectivity
ping $BASTION_IP_ADDR -c 10 || true
echo "exit" | curl "telnet://$BASTION_IP_ADDR:22" && echo "SSH port is opened"|| echo "status = $?"

cp $SSH_KEY_PATH $SSH_KEY
chmod 600 $SSH_KEY

git clone https://github.com/shaior/eco-gosystem.git --depth=1 -b telco-ci-init ${SHARED_DIR}/eco-gosystem
cd ${SHARED_DIR}/eco-gosystem/telco-ci/ 
ansible-playbook playbook.yml -i inventory -vvvv

