#!/bin/bash

set -o nounset
set -o errexit
set -o pipefail

echo "************ baremetalds devscripts setup command ************"

# Fetch packet basic configuration
# shellcheck source=/dev/null
source "${SHARED_DIR}/packet-conf.sh"

# Get dev-scripts logs
finished()
{
  set +e

  # Get dev-scripts logs
  echo "dev-scripts setup completed, fetching logs"
  ssh "${SSHOPTS[@]}" "root@${IP}" tar -czf - /root/dev-scripts/logs | tar -C "${ARTIFACT_DIR}" -xzf -
  sed -i -e 's/.*auths.*/*** PULL_SECRET ***/g' "${ARTIFACT_DIR}"/root/dev-scripts/logs/*
}
trap finished EXIT TERM

# Copy dev-scripts source from current directory to the remote server
tar -czf - . | ssh "${SSHOPTS[@]}" "root@${IP}" "cat > /root/dev-scripts.tar.gz"

# Prepare configuration and run dev-scripts
scp "${SSHOPTS[@]}" "${CLUSTER_PROFILE_DIR}/pull-secret" "root@${IP}:pull-secret"

# Additional mechanism to inject dev-scripts additional variables directly 
# from a multistage step configuration.
# Backward compatible with the previous approach based on creating the
# dev-scripts-additional-config file from a multistage step command
if [[ -n "${DEVSCRIPTS_CONFIG:-}" ]]; then
  readarray -t config <<< "${DEVSCRIPTS_CONFIG}"
  for var in "${config[@]}"; do
    if [[ ! -z "${var}" ]]; then 
      echo "export ${var}" >> "${SHARED_DIR}/dev-scripts-additional-config"
    fi
  done
fi

# Copy additional dev-script configuration provided by the the job, if present
if [[ -e "${SHARED_DIR}/dev-scripts-additional-config" ]]
then
  scp "${SSHOPTS[@]}" "${SHARED_DIR}/dev-scripts-additional-config" "root@${IP}:dev-scripts-additional-config"
fi

timeout -s 9 175m ssh "${SSHOPTS[@]}" "root@${IP}" bash - << EOF |& sed -e 's/.*auths.*/*** PULL_SECRET ***/g'

set -xeuo pipefail

yum install -y git sysstat sos
systemctl start sysstat

mkdir -p /tmp/artifacts

mkdir dev-scripts
tar -xzvf dev-scripts.tar.gz -C /root/dev-scripts
chown -R root:root dev-scripts

NVME_DEVICE="/dev/nvme0n1"
if [ -e "\$NVME_DEVICE" ];
then
  mkfs.xfs -f "\${NVME_DEVICE}"
  mkdir /opt/dev-scripts
  mount "\${NVME_DEVICE}" /opt/dev-scripts
fi

cd dev-scripts

cp /root/pull-secret /root/dev-scripts/pull_secret.json

echo "export OPENSHIFT_RELEASE_IMAGE=${OPENSHIFT_INSTALL_RELEASE_IMAGE}" >> /root/dev-scripts/config_root.sh
echo "export ADDN_DNS=\$(awk '/nameserver/ { print \$2;exit; }' /etc/resolv.conf)" >> /root/dev-scripts/config_root.sh
echo "export OPENSHIFT_CI=true" >> /root/dev-scripts/config_root.sh
echo "export WORKER_MEMORY=16384" >> /root/dev-scripts/config_root.sh

# Inject PR additional configuration, if available
if [[ -e /root/dev-scripts/dev-scripts-additional-config ]]
then
  cat /root/dev-scripts/dev-scripts-additional-config >> /root/dev-scripts/config_root.sh
# Inject job additional configuration, if available
elif [[ -e /root/dev-scripts-additional-config ]]
then
  cat /root/dev-scripts-additional-config >> /root/dev-scripts/config_root.sh
fi

echo 'export KUBECONFIG=/root/dev-scripts/ocp/ostest/auth/kubeconfig' >> /root/.bashrc

timeout -s 9 105m make

EOF
