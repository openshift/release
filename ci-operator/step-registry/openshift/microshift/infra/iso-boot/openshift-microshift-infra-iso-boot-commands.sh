#!/bin/bash
set -xeuo pipefail

trap 'CHILDREN=$(jobs -p); if test -n "${CHILDREN}"; then kill ${CHILDREN} && wait; fi' TERM

IP_ADDRESS="$(cat "${SHARED_DIR}"/public_address)"
HOST_USER="$(cat "${SHARED_DIR}"/ssh_user)"
INSTANCE_PREFIX="${HOST_USER}@${IP_ADDRESS}"

echo "Using Host $IP_ADDRESS"

mkdir -p "${HOME}/.ssh"
cat <<EOF >"${HOME}/.ssh/config"
Host ${IP_ADDRESS}
  User ${HOST_USER}
  IdentityFile ${CLUSTER_PROFILE_DIR}/ssh-privatekey
  StrictHostKeyChecking accept-new
  ServerAliveInterval 30
  ServerAliveCountMax 1200
EOF
chmod 0600 "${HOME}/.ssh/config"

# Install the settings for the scenario runner.  The ssh keys have
# already been copied into place in the iso-build step.
SETTINGS_FILE="${SHARED_DIR}/scenario_settings.sh"
cat <<EOF >"${SETTINGS_FILE}"
SSH_PUBLIC_KEY=\${HOME}/.ssh/id_rsa.pub
SSH_PRIVATE_KEY=\${HOME}/.ssh/id_rsa
EOF
scp "${SETTINGS_FILE}" "${INSTANCE_PREFIX}:/home/${HOST_USER}/microshift/test/"

trap 'scp -r ${INSTANCE_PREFIX}:/home/${HOST_USER}/microshift/_output/test-images/scenario-info ${ARTIFACT_DIR}' EXIT

# Run the in-repo ci phase script to create the VMs for the test scenarios.
ssh "${INSTANCE_PREFIX}" "/home/${HOST_USER}/microshift/test/bin/ci_phase_iso_boot.sh"
