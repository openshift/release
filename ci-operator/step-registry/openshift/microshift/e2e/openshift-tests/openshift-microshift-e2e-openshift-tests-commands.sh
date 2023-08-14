#!/usr/bin/env bash
set -xeuo pipefail

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

# Call wait regardless of the outcome of the kill command, in case some of the children are finished
# by the time we try to kill them. There is only 1 child now, but this is generic enough to allow N.
trap 'CHILDREN=$(jobs -p); if test -n "${CHILDREN}"; then kill ${CHILDREN} || true; wait; fi' TERM

#TODO need to call the tests and thats it. that is supposed to be done by the openshift-conformance-reduced job now. I should rename it, so lets start here.

SCENARIO_SOURCES="/home/${HOST_USER}/microshift/test/scenarios"
if [[ "$JOB_NAME" =~ .*periodic.* ]]; then
  SCENARIO_SOURCES="/home/${HOST_USER}/microshift/test/scenarios-periodics"
fi

# Run in background to allow trapping signals before the command ends. If running in foreground
# then TERM is queued until the ssh completes. This might be too long to fit in the grace period
# and get abruptly killed, which prevents gathering logs.
ssh "${INSTANCE_PREFIX}" "SCENARIO_SOURCES=${SCENARIO_SOURCES} /home/${HOST_USER}/microshift/test/bin/ci_phase_test.sh" &
# Run wait -n since we only have one background command. Should this change, please update the exit
# status handling.
wait -n
