#!/bin/bash

set -o nounset
set -o errexit
set -o pipefail

echo "************ baremetalds assisted operator setup command ************"

REPO_ROOT="$(git rev-parse --show-toplevel 2>/dev/null || pwd)"
# shellcheck source=ci-operator/step-registry/assisted/common/lib/assisted-common-lib-commands.sh
source "${REPO_ROOT}/ci-operator/step-registry/assisted/common/lib/assisted-common-lib-commands.sh"

assisted_load_host_contract

echo "Creating Ansible inventory file"
cat > "${SHARED_DIR}/inventory" <<-EOF

[primary]
${IP} ansible_user=${SSH_USER} ansible_ssh_user=${SSH_USER} ansible_ssh_private_key_file=${SSH_KEY_FILE} ansible_ssh_common_args="-o ConnectTimeout=5 -o UserKnownHostsFile=/dev/null -o ServerAliveInterval=90 -o LogLevel=ERROR"

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


tar -czf - . | ssh "${SSHOPTS[@]}" "$REMOTE_TARGET" "cat > /root/assisted-service.tar.gz"

# shellcheck disable=SC2087
ssh "${SSHOPTS[@]}" "$REMOTE_TARGET" bash - << EOF

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

images=(${ASSISTED_AGENT_IMAGE} ${ASSISTED_CONTROLLER_IMAGE} ${ASSISTED_INSTALLER_IMAGE} ${ASSISTED_IMAGE_SERVICE_IMAGE} ${ASSISTED_SERVICE_IMAGE})

cat << VARS >> /root/config
export DISCONNECTED="${DISCONNECTED:-}"
export ALLOW_CONVERGED_FLOW="${ALLOW_CONVERGED_FLOW:-}"

export INDEX_IMAGE="${INDEX_IMAGE}"

# reference internal image builds in order to be injected in the subscription object along with the index
export AGENT_IMAGE="${ASSISTED_AGENT_IMAGE}"
export CONTROLLER_IMAGE="${ASSISTED_CONTROLLER_IMAGE}"
export INSTALLER_IMAGE="${ASSISTED_INSTALLER_IMAGE}"
export IMAGE_SERVICE_IMAGE="${ASSISTED_IMAGE_SERVICE_IMAGE}"
export SERVICE_IMAGE="${ASSISTED_SERVICE_IMAGE}"

export PUBLIC_CONTAINER_REGISTRIES="\$(for image in \${images}; do echo \${image} | cut -d'/' -f1; done | sort -u | paste -sd ',' -)"
export ASSISTED_OPENSHIFT_INSTALL_RELEASE_IMAGE="${ASSISTED_OPENSHIFT_INSTALL_RELEASE_IMAGE}"

# Fix for disconnected Hive
export GO_REQUIRED_MIN_VERSION="1.14.4"
VARS

source /root/config

deploy/operator/deploy.sh

EOF
