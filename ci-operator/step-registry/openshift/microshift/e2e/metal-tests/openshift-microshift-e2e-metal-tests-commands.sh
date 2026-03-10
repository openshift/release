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

SCENARIO_SOURCES=$(get_source_dir "${SCENARIO_TYPE}")

echo "${INSTANCE_PREFIX}-${SCENARIO_SOURCES}-${EXCLUDE_CNCF_CONFORMANCE}-${TEST_EXECUTION_TIMEOUT}-${HOST_USER}"

# Run in background to allow trapping signals before the command ends. If running in foreground
# then TERM is queued until the ssh completes. This might be too long to fit in the grace period
# and get abruptly killed, which prevents gathering logs.
# shellcheck disable=SC2029
ssh "${INSTANCE_PREFIX}" "SCENARIO_SOURCES=${SCENARIO_SOURCES} EXCLUDE_CNCF_CONFORMANCE=${EXCLUDE_CNCF_CONFORMANCE} TEST_EXECUTION_TIMEOUT=${TEST_EXECUTION_TIMEOUT:-} /home/${HOST_USER}/microshift/test/bin/ci_phase_test.sh" &

# Give VMs time to start before continuing
echo "Waiting 10 minutes for VMs to start..."
sleep 600

# For debugging: sleep for additional time while keeping SSH process alive
echo "VMs should be running now. Sleeping for 4 hours to allow debugging."
echo "You can SSH to EC2 and check: ls -la ~/microshift/_output/test-images/scenario-info/"
sleep 14400

# Run wait -n since we only have one background command. Should this change, please update the exit
# status handling.
wait -n
