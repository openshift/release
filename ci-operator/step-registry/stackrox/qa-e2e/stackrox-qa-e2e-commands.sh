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
        # Strip <system-out> and <system-err> from JUnit XMLs before merging.
        # The merged file is copied to SHARED_DIR (a Kubernetes Secret, 1 MiB
        # limit). The QA E2E suite system-out alone reaches ~2.4 MiB. Our
        # junit2jira/flakechecker already read the full data in dispatch.sh.
        # Single-line pattern first: GNU sed range /start/,/end/d looks for end
        # on the NEXT line, so same-line matches would extend the range to EOF.
        find "${ARTIFACT_DIR}" -type f -name "*.xml" -print0 | xargs -0 -r \
            sed -i "/<system-out>.*<\/system-out>/d; /<system-out>/,/<\/system-out>/d; /<system-err>.*<\/system-err>/d; /<system-err>/,/<\/system-err>/d"
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