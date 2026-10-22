#!/bin/bash
set -euxo pipefail
shopt -s inherit_errexit

# Source ExitTrap library for JUnit XML post-processing
if [[ "${MAP_TESTS:-false}" == "true" ]]; then
    eval "$(
        typeset -a fetchCmd=()
        type -t wget 1>/dev/null && fetchCmd=(wget --timeout=30 -qO-) || fetchCmd=(curl --connect-timeout 10 --max-time 30 -fsSL)
        "${fetchCmd[@]}"             https://raw.githubusercontent.com/RedHatQE/OpenShift-LP-QE--Tools/refs/heads/main/libs/bash/ci-operator/interop/common/ExitTrap--PostProcessPrep.sh
    )"
    if type -t ExitTrap--PostProcessPrep; then
        trap '{
            LP_IO__ET_PPP__NEW_TS_NAME="${DR__RP__CR_COMP_NAME}--%s"                 ExitTrap--PostProcessPrep
            true
        }' EXIT
    else
        : "WARNING: ExitTrap--PostProcessPrep not available, skipping junit remapping"
    fi
fi


# Run ACM lifecycle smoke tests via openshift-tests with local extension binary
openshift-tests run-suite acm/lifecycle/smoke \
  --extension-local-binaries /usr/bin/acm-tests-ext.gz \
  --junit-dir "${ARTIFACT_DIR}/junit"
