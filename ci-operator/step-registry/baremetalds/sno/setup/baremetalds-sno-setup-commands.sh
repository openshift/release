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

# TODO: remove to use baked version instead of a hardcoded one
echo "export OPENSHIFT_INSTALL_RELEASE_IMAGE=registry.svc.ci.openshift.org/sno-dev/openshift-bip:0.2.0" >> /root/config
# echo "export OPENSHIFT_INSTALL_RELEASE_IMAGE=${RELEASE_IMAGE_LATEST}" >> /root/config
set -x

if [[ -e /root/sno-additional-config ]]
then
  cat /root/sno-additional-config >> /root/config
fi

echo "export KUBECONFIG=\${REPO_DIR}/build/kubeconfig" >> /root/.bashrc

source /root/config

timeout -s 9 105m make create_full_environment deploy_ibip

EOF
