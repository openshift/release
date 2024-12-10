#!/bin/bash
set -xeuo pipefail

# shellcheck disable=SC1091
source "${SHARED_DIR}/ci-functions.sh"
ci_script_prologue
trap_subprocesses_on_term

scp -r "${IP_ADDRESS}":/var/log/pcp/pmlogger/* "${ARTIFACT_DIR}/"
