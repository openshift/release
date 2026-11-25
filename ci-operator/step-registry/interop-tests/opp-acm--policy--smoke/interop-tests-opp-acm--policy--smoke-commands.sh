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
BIN_DIR="$(mktemp -d)"
trap 'ExitTrap--PostProcessPrep junit--acm-policy-smoke.xml; rm -rf "${BIN_DIR}"' EXIT

# Run ACM policy smoke tests via the standalone OTE binary: on OCP 4.22
# openshift-tests exposes `run SUITE` and no --extension-local-binaries flag.
mkdir -p "${ARTIFACT_DIR}/junit"
gunzip -c /usr/bin/acm-policy-tests.gz > "${BIN_DIR}/acm-policy-tests"
chmod +x "${BIN_DIR}/acm-policy-tests"
"${BIN_DIR}/acm-policy-tests" run-suite acm/policy/smoke \
  --junit-path "${ARTIFACT_DIR}/junit/junit-acm-policy-smoke.xml"
