#!/bin/bash

set -o nounset
set -o errexit
set -o pipefail

echo "************ baremetalds assisted setup command ************"

# Fetch packet basic configuration
# shellcheck source=/dev/null
source "${SHARED_DIR}/packet-conf.sh"

# Copy assisted source from current directory to the remote server
tar -czf - . | ssh "${SSHOPTS[@]}" "root@${IP}" "cat > /root/assisted.tar.gz"

# Prepare configuration and run
scp "${SSHOPTS[@]}" "${CLUSTER_PROFILE_DIR}/pull-secret" "root@${IP}:pull-secret"

# Additional mechanism to inject assisted additional variables directly
# from a multistage step configuration.
# Backward compatible with the previous approach based on creating the
# assisted-additional-config file from a multistage step command
if [[ -n "${ASSISTED_CONFIG:-}" ]]; then
  readarray -t config <<< "${ASSISTED_CONFIG}"
  for var in "${config[@]}"; do
    if [[ ! -z "${var}" ]]; then
      echo "export ${var}" >> "${SHARED_DIR}/assisted-additional-config"
    fi
  done
fi

if [[ -e "${SHARED_DIR}/assisted-additional-config" ]]
then
  scp "${SSHOPTS[@]}" "${SHARED_DIR}/assisted-additional-config" "root@${IP}:assisted-additional-config"
fi

timeout -s 9 175m ssh "${SSHOPTS[@]}" "root@${IP}" bash - << EOF |& sed -e 's/.*auths\{0,1\}".*/*** PULL_SECRET ***/g'

set -xeuo pipefail

yum install -y git sysstat sos
systemctl start sysstat

mkdir -p /tmp/artifacts

# NVMe makes it faster
NVME_DEVICE="/dev/nvme0n1"
REPO_DIR="/home/assisted"
if [ -e "\$NVME_DEVICE" ];
then
  mkfs.xfs -f "\${NVME_DEVICE}"
  mkdir -p "\${REPO_DIR}"
  mount "\${NVME_DEVICE}" "\${REPO_DIR}"
fi

tar -xzvf assisted.tar.gz -C "\${REPO_DIR}"
chown -R root:root "\${REPO_DIR}"

cd "\${REPO_DIR}"

set +x
echo "export PULL_SECRET='\$(cat /root/pull-secret)'" >> /root/config
set -x

# Override default images
echo "export AGENT_DOCKER_IMAGE=${ASSISTED_AGENT_IMAGE}" >> /root/config
echo "export CONTROLLER_IMAGE=${ASSISTED_CONTROLLER_IMAGE}" >> /root/config
echo "export INSTALLER_IMAGE=${ASSISTED_INSTALLER_IMAGE}" >> /root/config

if [ "\${OPENSHIFT_INSTALL_RELEASE_IMAGE:-}" = "" ]; then
    echo "export OPENSHIFT_INSTALL_RELEASE_IMAGE=${RELEASE_IMAGE_LATEST}" >> /root/config
fi

IMAGES=(${ASSISTED_AGENT_IMAGE} ${ASSISTED_CONTROLLER_IMAGE} ${ASSISTED_INSTALLER_IMAGE} ${RELEASE_IMAGE_LATEST})
CI_REGISTRIES=\$(for image in \${IMAGES}; do echo \${image} | cut -d'/' -f1; done | sort -u | paste -sd "," -)

echo "export PUBLIC_CONTAINER_REGISTRIES=quay.io,\${CI_REGISTRIES}" >> /root/config
echo "export ASSISTED_SERVICE_HOST=${IP}" >> /root/config
echo "export ADDITIONAL_PARAMS=-cvo" >> /root/config

if [[ -e /root/assisted-additional-config ]]
then
  cat /root/assisted-additional-config >> /root/config
fi

echo "export KUBECONFIG=\${REPO_DIR}/build/kubeconfig" >> /root/.bashrc

source /root/config

timeout -s 9 105m make \${MAKEFILE_TARGET:-all}

EOF
