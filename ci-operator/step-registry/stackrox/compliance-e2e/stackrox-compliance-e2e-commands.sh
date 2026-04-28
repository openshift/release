#!/bin/bash

# Enable strict mode options including xtrace (-x) and inherit_errexit
set -euxo pipefail; shopt -s inherit_errexit

# Map results by setting identifier prefix in tests suites names for reporting tools
# Merge original results into a single file and compress
# Send modified file to shared dir for Data Router Reporter step
if [ "${MAP_TESTS}" = "true" ]; then
    eval "$(
        curl -fsSL \
https://raw.githubusercontent.com/RedHatQE/OpenShift-LP-QE--Tools/refs/heads/main/libs/bash/ci-operator/interop/common/ExitTrap--PostProcessPrep.sh
    )"; trap '
        LP_IO__ET_PPP__NEW_TS_NAME="${REPORTPORTAL_CMP}--%s" \
            ExitTrap--PostProcessPrep junit--stackrox__compliance-e2e__stackrox-compliance-e2e.xml
    ' EXIT
fi

# Determine job name from test suite or job name safe
typeset job="${TEST_SUITE:-${JOB_NAME_SAFE#merge-}}"
job="${job#nightly-}"

# Logic for interop testing
if [ ! -f ".openshift-ci/dispatch.sh" ]; then
    if [ ! -d "stackrox" ]; then
        git clone https://github.com/stackrox/stackrox.git
    fi
    cd stackrox
fi

# dispatch.sh's exit trap (handle_dangling_processes in lib.sh) sends SIGTERM
# to all processes that are not itself, its children, or entrypoint/defunct.
# Ignore SIGTERM so this script survives and our EXIT trap runs cleanly.
trap '' TERM

# Execute dispatch script
.openshift-ci/dispatch.sh "${job}"

true