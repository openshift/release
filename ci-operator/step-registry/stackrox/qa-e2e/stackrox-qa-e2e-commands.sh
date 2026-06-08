#!/bin/bash

set -o errexit
set -o nounset
set -euxo pipefail; shopt -s inherit_errexit

# Map results by setting identifier prefix in tests suites names for reporting tools
# Merge original results into a single file and compress
# Send modified file to shared dir for Data Router Reporter step
if [ "${MAP_TESTS}" = "true" ]; then
    # Avoid conflicts with the older versioned yq from the image:
    # Write /tmp/bin/yq as a tiny script (#!/bin/sh; exit 1), so yq --version fails and ExitTrap EnsureReqs downloads latest yq (replacing the stub).
    eval "$(
        typeset -a _fURL=()
        type -t wget 1>/dev/null && _fURL=(wget -qO-) || _fURL=(curl -fsSL)
        "${_fURL[@]}" \
https://raw.githubusercontent.com/RedHatQE/OpenShift-LP-QE--Tools/refs/heads/main/libs/bash/ci-operator/interop/common/ExitTrap--PostProcessPrep.sh
    )"; trap '
        mkdir -p /tmp/bin
        printf "%s\n" "#!/bin/sh" "exit 1" > /tmp/bin/yq && chmod +x /tmp/bin/yq
        PATH="/tmp/bin:${PATH}"
        LP_IO__ET_PPP__NEW_TS_NAME="${DR__RP__CR_COMP_NAME}--%s" \
            ExitTrap--PostProcessPrep junit--stackrox__qa-e2e__stackrox-qa-e2e.xml
    ' EXIT
fi

job="${TEST_SUITE:-${JOB_NAME_SAFE#merge-}}"
job="${job#nightly-}"

# this part is used for interop opp testing under stolostron/policy-collection
if [ ! -f ".openshift-ci/dispatch.sh" ];then
  if [ ! -d "stackrox" ];then
    git clone https://github.com/stackrox/stackrox.git
  fi
  cd stackrox || exit
fi

.openshift-ci/dispatch.sh "${job}"

true