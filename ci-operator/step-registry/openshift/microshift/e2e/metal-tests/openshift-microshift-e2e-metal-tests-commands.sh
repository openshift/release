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

# Determine the tests to run depending on the job name and type.
# Exclude long-running tests from presubmit jobs.
EXCLUDE_CNCF_CONFORMANCE=false
if [ "${JOB_TYPE}" == "presubmit" ]; then
  EXCLUDE_CNCF_CONFORMANCE=true
fi

SCENARIO_TYPE=${SCENARIO_TYPE:-presubmits}
declare -A SCENARIO_DIRS=(
  [bootc-releases]="scenarios-bootc/releases:scenarios-bootc"
  [bootc-presubmits]="scenarios-bootc/presubmits:scenarios-bootc"
  [bootc-periodics]="scenarios-bootc/periodics:scenarios-bootc"
  [releases]="scenarios/releases:scenarios"
  [presubmits]="scenarios/presubmits:scenarios"
  [periodics]="scenarios/periodics:scenarios-periodics"
)

# Implement scenario directory check with fallbacks. Simplify or remove the
# function when the structure is homogenised in all the active releases.
function get_source_dir() {
  local -r scenario_type=$1
  local -r dirs="${SCENARIO_DIRS[$scenario_type]}"
  local -r fdir=$(echo "$dirs" | cut -d: -f1)
  local -r ndir=$(echo "$dirs" | cut -d: -f2)

  # We need the variable to expand on the client side
  # shellcheck disable=SC2029
  if ssh "${INSTANCE_PREFIX}" "[ -d \"${ndir}\" ]" ; then
    echo "${ndir}"
  else
    echo "${fdir}"
  fi
}

SCENARIO_SOURCES=$(get_source_dir "${SCENARIO_TYPE}")

# Run in background to allow trapping signals before the command ends. If running in foreground
# then TERM is queued until the ssh completes. This might be too long to fit in the grace period
# and get abruptly killed, which prevents gathering logs.
# shellcheck disable=SC2029
ssh "${INSTANCE_PREFIX}" "SCENARIO_SOURCES=${SCENARIO_SOURCES} EXCLUDE_CNCF_CONFORMANCE=${EXCLUDE_CNCF_CONFORMANCE} /home/${HOST_USER}/microshift/test/bin/ci_phase_test.sh" &
# Run wait -n since we only have one background command. Should this change, please update the exit
# status handling.
wait -n
