#!/bin/bash

set -o nounset
set -o errexit
set -o pipefail

echo "************ baremetalds assisted setup command ************"

# Fetch packet basic configuration
# shellcheck source=/dev/null
source "${SHARED_DIR}/packet-conf.sh"

export CI_CREDENTIALS_DIR=/var/run/assisted-installer-bot

# Copy assisted source from current directory to the remote server
tar -czf - . | ssh "${SSHOPTS[@]}" "root@${IP}" "cat > /root/assisted.tar.gz"

# Prepare configuration and run
scp "${SSHOPTS[@]}" "${CLUSTER_PROFILE_DIR}/pull-secret" "root@${IP}:pull-secret"
ssh "${SSHOPTS[@]}" "root@${IP}" "mkdir -p /root/.docker && cp /root/pull-secret /root/.docker/config.json"

if [ "${ENVIRONMENT}" != "local" ]; then

  if [ "${ENVIRONMENT}" = "production" ]; then
    remote_service_url="https://api.openshift.com"
    pull_secret_file="${CI_CREDENTIALS_DIR}/prod-pull-secret"
  else
    echo "Unknown environment ${ENVIRONMENT}"
    exit 1
  fi

  scp "${SSHOPTS[@]}" "${CI_CREDENTIALS_DIR}/offline-token" "root@${IP}:offline-token"
  scp "${SSHOPTS[@]}" "${pull_secret_file}" "root@${IP}:pull-secret"

  echo "export REMOTE_SERVICE_URL=${remote_service_url}" >> "${SHARED_DIR}/assisted-additional-config"
  echo "export NO_MINIKUBE=true" >> "${SHARED_DIR}/assisted-additional-config"
  echo "export MAKEFILE_TARGET='create_full_environment test_parallel'" >> "${SHARED_DIR}/assisted-additional-config"

  WORKER_DISK_SIZE=$(echo 120G | numfmt --from=iec)
  echo "export WORKER_DISK=${WORKER_DISK_SIZE}" >> "${SHARED_DIR}/assisted-additional-config"
fi

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

# Some Packet images have a file /usr/config left from the provisioning phase.
# The problem is that sos expects it to be a directory. Since we don't care
# about the Packet provisioner, remove the file if it's present.
test -f /usr/config && rm -f /usr/config || true

dnf install -y git sysstat sos jq make
systemctl start sysstat

mkdir -p /tmp/artifacts

REPO_DIR="/home/assisted"
mkdir -p "\${REPO_DIR}"
mkdir -p "\${REPO_DIR}"/minikube_home
echo "export MINIKUBE_HOME=\${REPO_DIR}/minikube_home" >> /root/config

# NVMe makes it faster
NVME_DEVICE="/dev/nvme0n1"
if [ -e "\$NVME_DEVICE" ];
then
  mkfs.xfs -f "\${NVME_DEVICE}"
  mount "\${NVME_DEVICE}" "\${REPO_DIR}"
fi

tar -xzvf assisted.tar.gz -C "\${REPO_DIR}"
chown -R root:root "\${REPO_DIR}"

cd "\${REPO_DIR}"

set +x
echo "export PULL_SECRET='\$(cat /root/pull-secret)'" >> /root/config
echo "export OFFLINE_TOKEN='\$(cat /root/offline-token)'" >> /root/config
set -x

# Save Prow variables that might become handy inside the Packet server
echo "export CI=true" >> /root/config
echo "export OPENSHIFT_CI=true" >> /root/config
echo "export REPO_NAME=${REPO_NAME:-}" >> /root/config
echo "export JOB_TYPE=${JOB_TYPE:-}" >> /root/config
echo "export PULL_NUMBER=${PULL_NUMBER:-}" >> /root/config
echo "export RELEASE_IMAGE_LATEST=${RELEASE_IMAGE_LATEST}" >> /root/config

# Override default images
echo "export SERVICE=${ASSISTED_SERVICE_IMAGE}" >> /root/config
echo "export AGENT_DOCKER_IMAGE=${ASSISTED_AGENT_IMAGE}" >> /root/config
echo "export CONTROLLER_IMAGE=${ASSISTED_CONTROLLER_IMAGE}" >> /root/config
echo "export INSTALLER_IMAGE=${ASSISTED_INSTALLER_IMAGE}" >> /root/config
# Most jobs and tests don't require this image, so this allows it as optional
if [ "${PROVIDER_IMAGE}" != "${ASSISTED_CONTROLLER_IMAGE}" ];
then
  echo "export PROVIDER_IMAGE=${PROVIDER_IMAGE}" >> /root/config
fi
# Most jobs and tests don't require this image, so this allows it as optional
if [ "${HYPERSHIFT_IMAGE}" != "${ASSISTED_CONTROLLER_IMAGE}" ];
then
  echo "export HYPERSHIFT_IMAGE=${HYPERSHIFT_IMAGE}" >> /root/config
fi

# expr command's return value is 1 in case of a false expression. We don't want to exit in this case.
set +e
IS_REHEARSAL=\$(expr "${REPO_OWNER:-}" = "openshift" "&" "${REPO_NAME:-}" = "release")
set -e

if [ "${JOB_TYPE:-}" = "presubmit" ] && (( ! \${IS_REHEARSAL} )); then
  if [ "${REPO_NAME:-}" = "assisted-service" ]; then
    echo "export SERVICE_BRANCH=${PULL_PULL_SHA:-master}" >> /root/config
  fi
else
  # Periodics run against latest release
  echo "export OPENSHIFT_INSTALL_RELEASE_IMAGE=${RELEASE_IMAGE_LATEST}" >> /root/config
fi

IMAGES=(${ASSISTED_AGENT_IMAGE} ${ASSISTED_CONTROLLER_IMAGE} ${ASSISTED_INSTALLER_IMAGE} ${RELEASE_IMAGE_LATEST})
CI_REGISTRIES=\$(for image in \${IMAGES}; do echo \${image} | cut -d'/' -f1; done | sort -u | paste -sd "," -)

echo "export PUBLIC_CONTAINER_REGISTRIES=quay.io,\${CI_REGISTRIES}" >> /root/config
echo "export ASSISTED_SERVICE_HOST=${IP}" >> /root/config
echo "export CHECK_CLUSTER_VERSION=True" >> /root/config
echo "export TEST_TEARDOWN=false" >> /root/config
echo "export TEST_FUNC=test_install" >> /root/config
echo "export INSTALLER_KUBECONFIG=\${REPO_DIR}/build/kubeconfig" >> /root/config

if [[ -e /root/assisted-additional-config ]]; then
  cat /root/assisted-additional-config >> /root/config
fi

source /root/config

make \${MAKEFILE_TARGET:-create_full_environment run test_parallel}

EOF


if [[ -n "${POST_INSTALL_COMMANDS:-}" ]]; then
  echo "${POST_INSTALL_COMMANDS}" > "${SHARED_DIR}/assisted-post-install.sh"
  scp "${SSHOPTS[@]}" "${SHARED_DIR}/assisted-post-install.sh" "root@${IP}:assisted-post-install.sh"
fi

# Post-installation commands
ssh "${SSHOPTS[@]}" "root@${IP}" bash - << EOF |& sed -e 's/.*auths\{0,1\}".*/*** PULL_SECRET ***/g'

set -xeuo pipefail

cd /home/assisted
source /root/config

echo "export KUBECONFIG=/home/assisted/build/kubeconfig" >> /root/.bashrc
export KUBECONFIG=/home/assisted/build/kubeconfig

if [[ -e "/root/assisted-post-install.sh" ]]; then
  source "/root/assisted-post-install.sh"
fi

EOF
