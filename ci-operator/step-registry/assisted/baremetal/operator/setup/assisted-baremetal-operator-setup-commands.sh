#!/bin/bash

set -o nounset
set -o errexit
set -o pipefail

echo "************ baremetalds assisted operator setup command ************"

# Fetch packet basic configuration
# shellcheck source=/dev/null
source "${SHARED_DIR}/packet-conf.sh"

echo "Creating Ansible inventory file"
cat > "${SHARED_DIR}/inventory" <<-EOF

[all]
${IP} ansible_user=root ansible_ssh_user=root ansible_ssh_private_key_file=${CLUSTER_PROFILE_DIR}/packet-ssh-key ansible_ssh_common_args="-o ConnectTimeout=5 -o StrictHostKeyChecking=no -o UserKnownHostsFile=/dev/null -o ServerAliveInterval=90 -o LogLevel=ERROR"

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

cd "\${REPO_DIR}"

echo "### Setup assisted installer..."

images=(${ASSISTED_AGENT_IMAGE} ${ASSISTED_CONTROLLER_IMAGE} ${ASSISTED_INSTALLER_IMAGE} ${ASSISTED_IMAGE_SERVICE_IMAGE})

cat << VARS >> /root/config
export DISCONNECTED="${DISCONNECTED:-}"
export ALLOW_CONVERGED_FLOW="${ALLOW_CONVERGED_FLOW:-}"

# TODO: remove this and support mirroring an index referenced by digest value
# https://issues.redhat.com/browse/MGMT-6858
export INDEX_IMAGE="\$(dirname ${INDEX_IMAGE})/pipeline:ci-index"

export PUBLIC_CONTAINER_REGISTRIES="\$(for image in \${images}; do echo \${image} | cut -d'/' -f1; done | sort -u | paste -sd ',' -)"
export ASSISTED_OPENSHIFT_INSTALL_RELEASE_IMAGE="${ASSISTED_OPENSHIFT_INSTALL_RELEASE_IMAGE}"

# Fix for disconnected Hive
export GO_REQUIRED_MIN_VERSION="1.14.4"
VARS

source /root/config

deploy/operator/deploy.sh

EOF
