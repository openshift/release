#!/bin/bash
set -e
set -o pipefail

date
echo "This is test case"
echo ${MY_TEST_VAR}
ls -l /var/run/temp-vault
cat /var/run/temp-vault/temp_secret

BASTION_IP="10.46.55.212"
BASTION_SSH_USER="$(< /var/run/temp-vault/ssh_user )"
SSH_PRIV_KEY_PATH="/var/run/temp-vault/ssh_priv_key"


ssh -o UserKnownHostsFile=/dev/null -o IdentityFile="${SSH_PRIV_KEY_PATH}" -o StrictHostKeyChecking=no ${BASTION_SSH_USER}@"${BASTION_IP}" \
      "hostname"

env

echo $CLUSTER_PROFILE_DIR