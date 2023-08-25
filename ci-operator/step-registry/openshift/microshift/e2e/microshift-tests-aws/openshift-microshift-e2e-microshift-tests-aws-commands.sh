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

set +x
STEP_NAME="${HOSTNAME##${JOB_NAME_SAFE}-}"
REPORT="${ARTIFACT_DIR}/custom-link-tools.html"
cat >>${REPORT} <<EOF
<html>
<head>
  <title>Logs</title>
  <meta name="description" content="Links to relevant logs">
  <link rel="stylesheet" type="text/css" href="/static/style.css">
  <link rel="stylesheet" type="text/css" href="/static/extensions/style.css">
  <link href="https://fonts.googleapis.com/css?family=Roboto:400,700" rel="stylesheet">
  <link rel="stylesheet" href="https://code.getmdl.io/1.3.0/material.indigo-pink.min.css">
  <link rel="stylesheet" type="text/css" href="/static/spyglass/spyglass.css">
  <style>
    a {
        display: inline-block;
        padding: 5px 20px 5px 20px;
        margin: 10px;
        border: 2px solid #4E9AF1;
        border-radius: 1em;
        text-decoration: none;
        color: #FFFFFF !important;
        text-align: center;
        transition: all 0.2s;
        background-color: #4E9AF1
    }

    a:hover {
        border-color: #FFFFFF;
    }
  </style>
</head>
<body>

  <a target="_blank" href="https://gcsweb-ci.apps.ci.l2s4.p1.openshiftapps.com/gcs/origin-ci-test/pr-logs/pull/${REPO_OWNER}_${REPO_NAME}/${PULL_NUMBER}/${JOB_NAME}/${BUILD_ID}/artifacts/${JOB_NAME_SAFE}/${STEP_NAME}/build-log.txt" title="Log of ${STEP_NAME}">build-log.txt</a>
  <a target="_blank" href="https://gcsweb-ci.apps.ci.l2s4.p1.openshiftapps.com/gcs/origin-ci-test/pr-logs/pull/${REPO_OWNER}_${REPO_NAME}/${PULL_NUMBER}/${JOB_NAME}/${BUILD_ID}/artifacts/${JOB_NAME_SAFE}/${STEP_NAME}/artifacts/log.html" title="Robot Framework's log.html">log.html</a>
  <a target="_blank" href="https://gcsweb-ci.apps.ci.l2s4.p1.openshiftapps.com/gcs/origin-ci-test/pr-logs/pull/${REPO_OWNER}_${REPO_NAME}/${PULL_NUMBER}/${JOB_NAME}/${BUILD_ID}/artifacts/${JOB_NAME_SAFE}/${STEP_NAME}/artifacts/" title="${STEP_NAME} artifacts">artifacts dir</a>

</body>
</html>
EOF
set -x

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
