#!/bin/bash
set -xeuo pipefail

# shellcheck disable=SC1091
source "${SHARED_DIR}/ci-functions.sh"
ci_script_prologue
trap_subprocesses_on_term

PMLOGS_DIR=/var/log/pcp/pmlogger
if ssh "${IP_ADDRESS}" "[ -d \"${PMLOGS_DIR}\" ]" ; then
    scp -r "${IP_ADDRESS}:${PMLOGS_DIR}/*" "${ARTIFACT_DIR}/"
else
    echo "ERROR: The '${PMLOGS_DIR}' directory does not exist on '${IP_ADDRESS}', skipping copy"
fi
