#!/bin/bash
set -euxo pipefail; shopt -s inherit_errexit

typeset -i exit_code=0

# Map results by setting identifier prefix in tests suites names for reporting tools
# Merge original results into a single file and compress
# Send modified file to shared dir for Data Router Reporter step
if [ "${MAP_TESTS}" = "true" ]; then
    eval "$(
        curl -fsSL \
            https://raw.githubusercontent.com/RedHatQE/OpenShift-LP-QE--Tools/refs/heads/main/libs/bash/ci-operator/interop/common/ExitTrap--PostProcessPrep.sh
    )"; trap '
        LP_IO__ET_PPP__NEW_TS_NAME="${DR__RP__CR_COMP_NAME}--%s" \
            ExitTrap--PostProcessPrep junit--gitops-operator__tests__gitops-operator-tests.xml
    ' EXIT
fi

scripts/openshift-CI-kuttl-tests.sh

make ginkgo
./bin/ginkgo -v --trace --timeout 210m --junit-report=openshift-gitops-parallel-e2e.xml -r ./test/openshift/e2e/ginkgo/parallel || exit_code=1

true
exit "${exit_code}"
