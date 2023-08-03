#!/usr/bin/env bash

set -xeuo pipefail

trap 'CHILDREN=$(jobs -p); if test -n "${CHILDREN}"; then kill ${CHILDREN} && wait; fi' TERM

IP_ADDRESS="$(cat ${SHARED_DIR}/public_address)"
HOST_USER="$(cat ${SHARED_DIR}/ssh_user)"

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

cat >> ${SHARED_DIR}/custom-links.txt << EOF
  <a target="_blank" href="https://gcsweb-ci.apps.ci.l2s4.p1.openshiftapps.com/gcs/origin-ci-test/pr-logs/pull/openshift_microshift/${PULL_NUMBER}/${JOB_NAME}/${BUILD_ID}/artifacts/${JOB_NAME_SAFE}/openshift-microshift-e2e-microshift-tests-aws/artifacts/log.html" title="Robot Framework's log.html">log.html</a>
EOF

# Robot Framework setup and execution.
cat << EOF >/tmp/variables.yaml
USHIFT_HOST: ${IP_ADDRESS}
USHIFT_USER: ${HOST_USER}
SSH_PRIV_KEY: ${CLUSTER_PROFILE_DIR}/ssh-privatekey
SSH_PORT: 22
EOF
/microshift/test/run.sh -o ${ARTIFACT_DIR} -i /tmp/variables.yaml -v /tmp/venv

# Bash e2e tests
firewall::open_port() {
  echo "no-op for aws"
}

firewall::close_port() {
  echo "no-op for aws"
}

export -f firewall::open_port
export -f firewall::close_port

USHIFT_IP="${IP_ADDRESS}" USHIFT_USER="${HOST_USER}" /microshift/e2e/main.sh run
