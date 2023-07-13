#!/usr/bin/env bash
set -xeuo pipefail

trap 'CHILDREN=$(jobs -p); if test -n "${CHILDREN}"; then kill ${CHILDREN} && wait; fi' TERM

IP_ADDRESS="$(cat "${SHARED_DIR}"/public_address)"
HOST_USER="$(cat "${SHARED_DIR}"/ssh_user)"
INSTANCE_PREFIX="${HOST_USER}@${IP_ADDRESS}"

echo "Using Host $IP_ADDRESS"

mkdir -p "${HOME}/.ssh"
cat <<EOF >"${HOME}/.ssh/config"
Host ${IP_ADDRESS}
  IdentityFile ${CLUSTER_PROFILE_DIR}/ssh-privatekey
  StrictHostKeyChecking accept-new
  ServerAliveInterval 30
  ServerAliveCountMax 1200
EOF
chmod 0600 "${HOME}/.ssh/config"

trap 'scp -r ${INSTANCE_PREFIX}:/home/${HOST_USER}/microshift/_output/test-images/scenario-info ${ARTIFACT_DIR}' EXIT

# Run the scenario tests, if the phase script exists
# (we can clean this up after the main PR lands)
cd /microshift/test || true
if [ -f ./bin/ci_phase_test.sh ]; then
    ./bin/ci_phase_test.sh
fi
