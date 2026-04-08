#!/bin/bash

set -o nounset
set -o errexit
set -o pipefail

echo "************ baremetalds single-node setup command ************"

# Fetch packet basic configuration
# shellcheck source=/dev/null
source "${SHARED_DIR}/packet-conf.sh"

# Get dev-scripts logs and other configuration
finished()
{
  # Make sure we always execute all of this, so we gather logs and installer status, even when
  # install fails.
  set +o pipefail
  set +o errexit

  echo "Fetching kubeconfig, other credentials..."
  scp "${SSHOPTS[@]}" "root@${IP}:/home/sno/build/ibip/auth/kubeconfig" "${SHARED_DIR}/"
  scp "${SSHOPTS[@]}" "root@${IP}:/home/sno/build/ibip/auth/kubeadmin-password" "${SHARED_DIR}/"

  # ESI nodes are all using the same IP with different ports (which is forwarded to 8213)
  PROXYPORT="8213"

  echo "Adding proxy-url in kubeconfig"
  sed -i "/- cluster/ a\    proxy-url: http://$IP:$PROXYPORT/" "${SHARED_DIR}"/kubeconfig

  echo "Restarting proxy container"
  ssh "${SSHOPTS[@]}" "root@${IP}" "podman restart external-squid"
}
trap finished EXIT TERM

echo "Creating Ansible inventory file"
cat > "${SHARED_DIR}/inventory" <<-EOF

[primary]
${IP} ansible_user=root ansible_ssh_user=root ansible_ssh_private_key_file=${CLUSTER_PROFILE_DIR}/packet-ssh-key ansible_ssh_common_args="-o ConnectTimeout=5 -o UserKnownHostsFile=/dev/null -o ServerAliveInterval=90 -o LogLevel=ERROR"

EOF

echo "Creating Ansible configuration file"
cat > "${SHARED_DIR}/ansible.cfg" <<-EOF

[defaults]
callbacks_enabled = profile_tasks
host_key_checking = False

verbosity = 2
stdout_callback = ansible.builtin.default
bin_ansible_callbacks = True

[callback_default]
result_format = yaml

EOF

# Copy assisted-test-infra source from current directory to the remote server
tar -czf - . | ssh "${SSHOPTS[@]}" "root@${IP}" "cat > /root/sno.tar.gz"

# Prepare configuration and run
scp "${SSHOPTS[@]}" "${CLUSTER_PROFILE_DIR}/pull-secret" "root@${IP}:pull-secret"

# Additional mechanism to inject sno additional variables directly
# from a multistage step configuration.
# Backward compatible with the previous approach based on creating the
# sno-additional-config file from a multistage step command
if [[ -n "${SNO_CONFIG:-}" ]]; then
  readarray -t config <<< "${SNO_CONFIG}"
  for var in "${config[@]}"; do
    if [[ ! -z "${var}" ]]; then
      echo "export ${var}" >> "${SHARED_DIR}/sno-additional-config"
    fi
  done
fi

if [[ -e "${SHARED_DIR}/sno-additional-config" ]]
then
  scp "${SSHOPTS[@]}" "${SHARED_DIR}/sno-additional-config" "root@${IP}:sno-additional-config"
fi

# Copy additional manifests
ssh "${SSHOPTS[@]}" "root@${IP}" "rm -rf /root/sno-additional-manifests && mkdir /root/sno-additional-manifests"
while IFS= read -r -d '' item
do
  echo "Copying ${item}"
  scp "${SSHOPTS[@]}" "${item}" "root@${IP}:sno-additional-manifests/"
done < <( find "${SHARED_DIR}" \( -name "manifest_*.yml" -o -name "manifest_*.yaml" \) -print0)
echo -e "\nThe following manifests will be included at installation time:"
ssh "${SSHOPTS[@]}" "root@${IP}" "find /root/sno-additional-manifests -name manifest_*.yml -o -name manifest_*.yaml"

# TODO: Figure out way to get these parameters (used by deploy_ibip) without hardcoding them here
# preferrably by making deploy_ibip / makefile perform these configurations itself in the assisted_test_infra
# repo.
export SINGLE_NODE_IP_ADDRESS="192.168.127.10"
export CLUSTER_NAME="test-infra-cluster"
export CLUSTER_API_DOMAIN="api.${CLUSTER_NAME}.redhat.com"
export CLUSTER_INGRESS_SUB_DOMAIN="apps.${CLUSTER_NAME}.redhat.com"
export INGRESS_APPS=(oauth-openshift console-openshift-console canary-openshift-ingress-canary thanos-querier-openshift-monitoring)

timeout -s 9 175m ssh "${SSHOPTS[@]}" "root@${IP}" bash - << EOF |& sed -e 's/.*auths.*/*** PULL_SECRET ***/g'

set -xeuo pipefail

# Some Packet images have a file /usr/config left from the provisioning phase.
# The problem is that sos expects it to be a directory. Since we don't care
# about the Packet provisioner, remove the file if it's present.
test -f /usr/config && rm -f /usr/config || true

dnf install -y git sysstat sos make
systemctl start sysstat

mkdir -p /tmp/artifacts

REPO_DIR="/home/sno"
mkdir -p "\${REPO_DIR}"

# NVMe makes it faster
NVME_DEVICE="/dev/nvme0n1"
if [ -e "\$NVME_DEVICE" ];
then
  mkfs.xfs -f "\${NVME_DEVICE}"
  mount "\${NVME_DEVICE}" "\${REPO_DIR}"
fi

tar -xzvf sno.tar.gz -C "\${REPO_DIR}"
chown -R root:root "\${REPO_DIR}"

cd "\${REPO_DIR}"

set +x
echo "export PULL_SECRET='\$(cat /root/pull-secret)'" >> /root/config
echo "export NO_MINIKUBE=true" >> /root/config
# 40GB Size
echo "export WORKER_DISK=40000000000" >> /root/config

echo "export OPENSHIFT_INSTALL_RELEASE_IMAGE=${OPENSHIFT_INSTALL_RELEASE_IMAGE:-${RELEASE_IMAGE_LATEST}}" >> /root/config

set -x

if [[ -e /root/sno-additional-config ]]
then
  cat /root/sno-additional-config >> /root/config
fi

echo "export KUBECONFIG=\${REPO_DIR}/build/ibip/auth/kubeconfig" >> /root/.bashrc

source /root/config

# Configure dnsmasq
echo "${SINGLE_NODE_IP_ADDRESS} ${CLUSTER_API_DOMAIN}" | tee --append /etc/hosts
for ingress_app in ${INGRESS_APPS[@]}; do
  echo "${SINGLE_NODE_IP_ADDRESS} \${ingress_app}.${CLUSTER_INGRESS_SUB_DOMAIN}" | tee --append /etc/hosts
done
echo "export SINGLE_NODE_IP_ADDRESS=${SINGLE_NODE_IP_ADDRESS}" >> /root/config

# Keeping for posterity, this breaks ofcir nodes resolve config
#echo Reloading NetworkManager systemd configuration
#systemctl reload NetworkManager

echo "Enabling podman rest api"
systemctl --user enable --now podman.socket

export TEST_ARGS="TEST_FUNC=${TEST_FUNC}"
if [[ -e /root/sno-additional-manifests ]]
then
  TEST_ARGS="\${TEST_ARGS} ADDITIONAL_MANIFEST_DIR=/root/sno-additional-manifests"
fi
timeout -s 9 105m make setup deploy_ibip \${TEST_ARGS}

EOF
