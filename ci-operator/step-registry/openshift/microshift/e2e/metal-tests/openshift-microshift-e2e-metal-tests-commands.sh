#!/usr/bin/env bash
set -xeuo pipefail
export PS4='+ $(date "+%T.%N") \011'

finalize() {
  scp -r "${INSTANCE_PREFIX}:/home/${HOST_USER}/microshift/_output/test-images/scenario-info" "${ARTIFACT_DIR}"

  set +x
  STEP_NAME="${HOSTNAME##${JOB_NAME_SAFE}-}"
  REPORT="${ARTIFACT_DIR}/custom-link-tools.html"
  JOB_URL_PATH="logs"
  if [ "${JOB_TYPE}" == "presubmit" ]; then
    JOB_URL_PATH="pr-logs/pull/${REPO_OWNER}_${REPO_NAME}/${PULL_NUMBER}"
  fi
  URL="https://gcsweb-ci.apps.ci.l2s4.p1.openshiftapps.com/gcs/origin-ci-test/${JOB_URL_PATH}/${JOB_NAME}/${BUILD_ID}/artifacts/${JOB_NAME_SAFE}/${STEP_NAME}/${ARTIFACT_DIR#/logs/}/scenario-info"
  cat >>${REPORT} <<EOF
<html>
<head>
  <title>Test logs</title>
  <meta name="description" content="Links to relevant logs">
  <link rel="stylesheet" type="text/css" href="/static/style.css">
  <link rel="stylesheet" type="text/css" href="/static/extensions/style.css">
  <link href="https://fonts.googleapis.com/css?family=Roboto:400,700" rel="stylesheet">
  <link rel="stylesheet" href="https://code.getmdl.io/1.3.0/material.indigo-pink.min.css">
  <link rel="stylesheet" type="text/css" href="/static/spyglass/spyglass.css">
  <style>
    body {
      background-color: #303030;
    }
    a {
        color: #FFFFFF;
    }
    a:hover {
      text-decoration: underline;
    }
    p {
      color: #FFFFFF;
    }
  </style>
</head>
<body>
EOF
  for test in ${ARTIFACT_DIR}/scenario-info/*; do
    testname=$(basename "${test}")
    cat >>${REPORT} <<EOF
    <p>${testname}:&nbsp;
    <a target="_blank" href="${URL}/${testname}">directory</a>
    &nbsp;/&nbsp;<a target="_blank" href="${URL}/${testname}/run.log">run.log</a>
EOF
    if [ -f ${test}/log.html ]; then
      cat >>${REPORT} <<EOF
    &nbsp;/&nbsp;<a target="_blank" href="${URL}/${testname}/log.html">RF log</a>
EOF
    fi
    cat >>${REPORT} <<EOF
    </p>
EOF
  done
  cat >>${REPORT} <<EOF
</body>
</html>
EOF
  set -x
}

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

trap 'finalize' EXIT
# Call wait regardless of the outcome of the kill command, in case some of the children are finished
# by the time we try to kill them. There is only 1 child now, but this is generic enough to allow N.
trap 'CHILDREN=$(jobs -p); if test -n "${CHILDREN}"; then kill ${CHILDREN} || true; wait; fi' TERM

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
