#!/usr/bin/env bash

set -xeuo pipefail

trap 'CHILDREN=$(jobs -p); if test -n "${CHILDREN}"; then kill ${CHILDREN} && wait; fi' TERM

IP_ADDRESS="$(cat "${SHARED_DIR}"/public_address)"

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

# Bash e2e tests
run_e2e() {
  VM_IP="$(cat ${SHARED_DIR}/public_address)"
  VM_PORT="$(cat ${SHARED_DIR}/ssh_port_0)"
  VM_USER="$(cat ${SHARED_DIR}/user_0)"
  cat << EOF >/tmp/e2e.yaml
USHIFT_HOST: ${VM_IP}
USHIFT_USER: ${VM_USER}
SSH_PRIV_KEY: ${CLUSTER_PROFILE_DIR}/ssh-privatekey
SSH_PORT: ${VM_PORT}
EOF
  /microshift/test/run.sh -o "${ARTIFACT_DIR}/e2e" -i /tmp/e2e.yaml -v /tmp/venv /microshift/test/suites-ostree
}

#TODO if more tests are to be run in parallel the code should go in here.
# For now run e2e only.

FAIL=0
# Test : VM mapping
# e2e:vm0
run_e2e &

for job in $(jobs -p)
do
  echo "$job"
  wait "$job" || ((FAIL+=1))
done

if [ "$FAIL" != "0" ];
then
  echo "Tests failed. Check junit for details"
  exit 1
fi

