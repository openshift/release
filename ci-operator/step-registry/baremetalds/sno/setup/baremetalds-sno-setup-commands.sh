#!/bin/bash

set -o nounset
set -o errexit
set -o pipefail

echo "************ baremetalds single-node setup command ************"

# Fetch packet basic configuration
# shellcheck source=/dev/null
source "${SHARED_DIR}/packet-conf.sh"

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

# TODO: Figure out way to get these parameters (used by deploy_ibip) without hardcoding them here
# preferrably by making deploy_ibip / makefile perform these configurations itself in the assisted_test_infra
# repo.
export SINGLE_NODE_IP_ADDRESS="192.168.126.10"
export CLUSTER_NAME="test-infra-cluster"
export CLUSTER_API_DOMAIN="api.${CLUSTER_NAME}.redhat.com"

timeout -s 9 175m ssh "${SSHOPTS[@]}" "root@${IP}" bash - << EOF |& sed -e 's/.*auths.*/*** PULL_SECRET ***/g'

set -xeuo pipefail

yum install -y git sysstat sos
systemctl start sysstat

mkdir -p /tmp/artifacts

# NVMe makes it faster
NVME_DEVICE="/dev/nvme0n1"
REPO_DIR="/home/sno"
if [ -e "\$NVME_DEVICE" ];
then
  mkfs.xfs -f "\${NVME_DEVICE}"
  mkdir -p "\${REPO_DIR}"
  mount "\${NVME_DEVICE}" "\${REPO_DIR}"
fi

tar -xzvf sno.tar.gz -C "\${REPO_DIR}"
chown -R root:root "\${REPO_DIR}"

cd "\${REPO_DIR}"

set +x
echo "export PULL_SECRET='\$(cat /root/pull-secret)'" >> /root/config
echo "export NO_MINIKUBE=true" >> /root/config

echo "export OPENSHIFT_INSTALL_RELEASE_IMAGE=${RELEASE_IMAGE_LATEST}" >> /root/config

set -x

if [[ -e /root/sno-additional-config ]]
then
  cat /root/sno-additional-config >> /root/config
fi

echo "export KUBECONFIG=\${REPO_DIR}/build/ibip/auth/kubeconfig" >> /root/.bashrc

source /root/config

# Configure dnsmasq
echo "${SINGLE_NODE_IP_ADDRESS} ${CLUSTER_API_DOMAIN}" | tee --append /etc/hosts
echo Reloading NetworkManager systemd configuration
systemctl reload NetworkManager

timeout -s 9 105m make create_full_environment deploy_ibip

EOF
