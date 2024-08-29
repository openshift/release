#!/bin/bash
set -xeuo pipefail

curl https://raw.githubusercontent.com/openshift/release/master/ci-operator/step-registry/openshift/microshift/includes/openshift-microshift-includes-commands.sh -o /tmp/ci-functions.sh
# shellcheck disable=SC1091
source /tmp/ci-functions.sh
ci_script_prologue
trap_subprocesses_on_term

finalize() {
  scp -r "${INSTANCE_PREFIX}:/home/${HOST_USER}/microshift/_output/test-images/scenario-info" "${ARTIFACT_DIR}"

  set +x
  STEP_NAME="${HOSTNAME##${JOB_NAME_SAFE}-}"
  REPORT="${ARTIFACT_DIR}/custom-link-tools.html"
  JOB_URL_PATH="logs"
  if [ "${JOB_TYPE}" == "presubmit" ]; then
    JOB_URL_PATH="pr-logs/pull/${REPO_OWNER}_${REPO_NAME}/${PULL_NUMBER}"
  fi
  URL="https://gcsweb-ci.apps.ci.l2s4.p1.openshiftapps.com/gcs/test-platform-results/${JOB_URL_PATH}/${JOB_NAME}/${BUILD_ID}/artifacts/${JOB_NAME_SAFE}/${STEP_NAME}/${ARTIFACT_DIR#/logs/}/scenario-info"
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

trap 'finalize' EXIT


# Implement scenario directory check with fallbacks. Simplify or remove the
# function when the structure is homogenised in all the active releases.
function get_source_dir() {
  local -r base="/home/${HOST_USER}/microshift/test"
  local -r ndir="${base}/$1"
  local -r fdir="${base}/$2"

  # We need the variable to expand on the client side
  # shellcheck disable=SC2029
  if ssh "${INSTANCE_PREFIX}" "[ -d \"${ndir}\" ]" ; then
    echo "${ndir}"
  else
    echo "${fdir}"
  fi
}

if [[ ${JOB_NAME} =~ .*bootc.* ]] ; then
  SCENARIO_SOURCES=$(get_source_dir "scenarios-bootc/presubmits" "scenarios-bootc")
  if [[ "${JOB_NAME}" =~ .*periodic.* ]] && [[ ! "${JOB_NAME}" =~ .*nightly-presubmit.* ]]; then
    SCENARIO_SOURCES=$(get_source_dir "scenarios-bootc/periodics" "scenarios-bootc")
  fi
else
  SCENARIO_SOURCES=$(get_source_dir "scenarios/presubmits" "scenarios")
  if [[ "${JOB_NAME}" =~ .*periodic.* ]] && [[ ! "${JOB_NAME}" =~ .*nightly-presubmit.* ]]; then
    SCENARIO_SOURCES=$(get_source_dir "scenarios/periodics" "scenarios-periodics")
  fi
fi

# Run in background to allow trapping signals before the command ends. If running in foreground
# then TERM is queued until the ssh completes. This might be too long to fit in the grace period
# and get abruptly killed, which prevents gathering logs.
ssh "${INSTANCE_PREFIX}" "SCENARIO_SOURCES=${SCENARIO_SOURCES} /home/${HOST_USER}/microshift/test/bin/ci_phase_test.sh" &
# Run wait -n since we only have one background command. Should this change, please update the exit
# status handling.
wait -n
