#!/bin/bash
set -euxo pipefail
shopt -s inherit_errexit

# Source ExitTrap library for JUnit XML post-processing
eval "$(
    typeset -a _fURL=()
    type -t wget 1>/dev/null && _fURL=(wget -nv -O-) || _fURL=(curl -fsSL)
    "${_fURL[@]}" \
        https://raw.githubusercontent.com/RedHatQE/OpenShift-LP-QE--Tools/refs/heads/main/libs/bash/ci-operator/interop/common/ExitTrap--PostProcessPrep.sh
)"
trap 'ExitTrap--PostProcessPrep' EXIT

# Run all ACM policy tests via openshift-tests with local extension binary
openshift-tests run-suite acm/policy/all \
  --extension-local-binaries /usr/bin/acm-policy-tests.gz \
  --junit-dir "${ARTIFACT_DIR}/junit"
