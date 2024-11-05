#!/bin/bash
set -xeuo pipefail

# shellcheck disable=SC1091
source "${SHARED_DIR}/ci-functions.sh"
ci_script_prologue
trap_subprocesses_on_term

finalize() {
  scp -r "${INSTANCE_PREFIX}:/home/${HOST_USER}/microshift/_output/test-images/scenario-info" "${ARTIFACT_DIR}"
  ci_custom_link_report "Test Logs" "openshift-microshift-e2e-metal-tests"
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
# shellcheck disable=SC2029
ssh "${INSTANCE_PREFIX}" "SCENARIO_SOURCES=${SCENARIO_SOURCES} /home/${HOST_USER}/microshift/test/bin/ci_phase_test.sh" &
# Run wait -n since we only have one background command. Should this change, please update the exit
# status handling.
wait -n
