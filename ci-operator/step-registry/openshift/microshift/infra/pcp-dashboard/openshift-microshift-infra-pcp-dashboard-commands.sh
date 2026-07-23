#!/bin/bash
set -xeuo pipefail

# shellcheck disable=SC1091
source "${SHARED_DIR}/ci-functions.sh"
ci_script_prologue
trap_subprocesses_on_term

EDGE_TOOLING_DIR="${EDGE_TOOLING_DIR:-/opt/app-root/src/edge-tooling}"
PCP_SCRIPTS="${EDGE_TOOLING_DIR}/plugins/microshift-ci/scripts/pcp-graphs"
REMOTE_SCENARIO_DIR="/home/${HOST_USER}/microshift/_output/test-images/scenario-info"
LOCAL_ARTIFACTS=$(mktemp -d)

# Selectively copy PCP archives and junit.xml from the hypervisor
echo "Copying PCP archives and junit.xml from ${INSTANCE_PREFIX}..."
ssh "${INSTANCE_PREFIX}" \
    "cd ${REMOTE_SCENARIO_DIR} && \
     find . \( -name 'pcp-archives.tar' -o -name 'junit.xml' \) -print0 | \
     tar cf - --null -T -" | tar xf - -C "${LOCAL_ARTIFACTS}/"

# Copy hypervisor PCP logs if available
PMLOGS_DIR=/var/log/pcp/pmlogger
if ssh "${INSTANCE_PREFIX}" "[ -d \"${PMLOGS_DIR}\" ]" ; then
    mkdir -p "${LOCAL_ARTIFACTS}/pmlogs"
    if ! scp -r "${INSTANCE_PREFIX}:${PMLOGS_DIR}/"* "${LOCAL_ARTIFACTS}/pmlogs/" ; then
        echo "WARNING: failed to copy hypervisor pmlogger data, skipping"
    fi
fi

# Generate the interactive PCP dashboard
echo "Generating PCP dashboard..."
bash "${PCP_SCRIPTS}/generate-dashboard.sh" \
    --local "${LOCAL_ARTIFACTS}" \
    --title "Test PCP" \
    --output "${ARTIFACT_DIR}/custom-link-pcp.html"

rm -rf "${LOCAL_ARTIFACTS}"
