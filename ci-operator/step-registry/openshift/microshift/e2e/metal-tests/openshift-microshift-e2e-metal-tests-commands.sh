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

# Extract version from JOB_NAME, expecting format 4.## (e.g., 4.17, 4.18, 4.19, etc.)
RELEASE_VERSION=""
if [[ "${JOB_NAME}" =~ 4\.([0-9]+) ]]; then
  RELEASE_VERSION="${BASH_REMATCH[1]}"
fi

IS_BOOTC=false
IS_RELEASE=false
IS_PERIODIC=false
IS_NIGHTLY_PRESUBMIT=false
IS_OLD_VERSION=false

[[ "${JOB_NAME}" =~ .*bootc.* ]] && IS_BOOTC=true
[[ "${JOB_NAME}" =~ .*release.* ]] && IS_RELEASE=true
[[ "${JOB_NAME}" =~ .*periodic.* ]] && IS_PERIODIC=true
[[ "${JOB_NAME}" =~ .*nightly-presubmit.* ]] && IS_NIGHTLY_PRESUBMIT=true
if [[ -n "${RELEASE_VERSION}" && "${RELEASE_VERSION}" -le 18 ]]; then
  IS_OLD_VERSION=true
fi

SCENARIO_MAIN=""
SCENARIO_FALLBACK=""

if $IS_BOOTC; then
  SCENARIO_FALLBACK="scenarios-bootc"
  if $IS_RELEASE; then
    if $IS_OLD_VERSION; then
      SCENARIO_MAIN="scenarios-bootc/presubmits"
    else
      SCENARIO_MAIN="scenarios-bootc/releases"
    fi
  elif $IS_PERIODIC && ! $IS_NIGHTLY_PRESUBMIT; then
    SCENARIO_MAIN="scenarios-bootc/periodics"
  else
    SCENARIO_MAIN="scenarios-bootc/presubmits"
  fi
else
  if $IS_PERIODIC && ! $IS_NIGHTLY_PRESUBMIT; then
    SCENARIO_MAIN="scenarios/periodics"
    SCENARIO_FALLBACK="scenarios-periodics"
  else
    SCENARIO_FALLBACK="scenarios"
    if $IS_RELEASE; then
      if $IS_OLD_VERSION; then
        SCENARIO_MAIN="scenarios/presubmits"
      else
        SCENARIO_MAIN="scenarios/releases"
      fi
    else
      SCENARIO_MAIN="scenarios/presubmits"
    fi
  fi
fi

SCENARIO_SOURCES=$(get_source_dir "$SCENARIO_MAIN" "$SCENARIO_FALLBACK")

# Check that the directory exists before proceeding
if ! ssh "${INSTANCE_PREFIX}" "[ -d \"${SCENARIO_SOURCES}\" ]" ; then
  echo "Error: Scenario directory ${SCENARIO_SOURCES} does not exist on remote host."
  exit 1
fi

# Run in background to allow trapping signals before the command ends. If running in foreground
# then TERM is queued until the ssh completes. This might be too long to fit in the grace period
# and get abruptly killed, which prevents gathering logs.
# shellcheck disable=SC2029
ssh "${INSTANCE_PREFIX}" "SCENARIO_SOURCES=${SCENARIO_SOURCES} EXCLUDE_CNCF_CONFORMANCE=${EXCLUDE_CNCF_CONFORMANCE} /home/${HOST_USER}/microshift/test/bin/ci_phase_test.sh" &
# Run wait -n since we only have one background command. Should this change, please update the exit
# status handling.
wait -n
