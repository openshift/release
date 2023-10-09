#!/bin/bash

set -o nounset
set -o errexit
set -o pipefail

echo "************ baremetals agentserviceconfig config command ************"

source "${SHARED_DIR}/packet-conf.sh"

echo "Creating Ansible inventory file"
cat > "${SHARED_DIR}/inventory" <<-EOF

[primary]
${IP} ansible_user=root ansible_ssh_user=root ansible_ssh_private_key_file=${CLUSTER_PROFILE_DIR}/packet-ssh-key ansible_ssh_common_args="-o ConnectTimeout=5 -o UserKnownHostsFile=/dev/null -o ServerAliveInterval=90 -o LogLevel=ERROR"

EOF

echo "Creating Ansible configuration file"
cat > "${SHARED_DIR}/ansible.cfg" <<-EOF

[defaults]
callback_whitelist = profile_tasks
host_key_checking = False

verbosity = 2
stdout_callback = yaml
bin_ansible_callbacks = True

EOF

tar -czf - . | ssh "${SSHOPTS[@]}" "root@${IP}" "cat > /root/assisted-service.tar.gz"

# shellcheck disable=SC2087
ssh "${SSHOPTS[@]}" "root@${IP}" bash - << EOF

# prepending each printed line with a timestamp
exec > >(awk '{ print strftime("[%Y-%m-%d %H:%M:%S]"), \$0 }') 2>&1

set -xeo pipefail

cd /root/dev-scripts
source common.sh
source utils.sh
source network.sh
export -f wrap_if_ipv6 ipversion

REPO_DIR="/home/assisted-service"
if [ ! -d "\${REPO_DIR}" ]; then
  mkdir -p "\${REPO_DIR}"

  echo "### Untar assisted-service code..."
  tar -xzvf /root/assisted-service.tar.gz -C "\${REPO_DIR}"
fi

cd "\${REPO_DIR}/deploy/operator"

cat << VARS >> /root/config
export DISCONNECTED="${DISCONNECTED:-}"
VARS

source /root/config

curl https://raw.githubusercontent.com/LiangquanLi930/deployhypershift/main/config_agentserviceconfig.sh | bash -x
set -x
EOF