#!/bin/bash
set -xeuo pipefail

# shellcheck disable=SC1091
source "${SHARED_DIR}/ci-functions.sh"
ci_script_prologue
trap_subprocesses_on_term
trap_install_status_exit_code $EXIT_CODE_AWS_EC2_LOG_FAILURE

scp "${INSTANCE_PREFIX}:/tmp/init_output.txt" "${ARTIFACT_DIR}/init_ec2_output.txt"
