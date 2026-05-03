#!/bin/bash
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
            ExitTrap--PostProcessPrep junit--cnv__interop-tests__cnv-tests-e2e-deploy.xml
    ' EXIT
fi

# Set cluster variables
# CLUSTER_NAME=$(cat "${SHARED_DIR}/CLUSTER_NAME")
# CLUSTER_DOMAIN="${CLUSTER_DOMAIN:-release-ci.cnv-qe.rhood.us}"
typeset binFolder=''
typeset exit_code=0
binFolder="$(mktemp -d /tmp/bin.XXXX)"

# Exports
# export CLUSTER_NAME CLUSTER_DOMAIN
export PATH="${binFolder}:${PATH}"

# Unset the following environment variables to avoid issues with oc command
unset KUBERNETES_SERVICE_PORT_HTTPS
unset KUBERNETES_SERVICE_PORT
unset KUBERNETES_PORT_443_TCP
unset KUBERNETES_PORT_443_TCP_PROTO
unset KUBERNETES_PORT_443_TCP_ADDR
unset KUBERNETES_SERVICE_HOST
unset KUBERNETES_PORT
unset KUBERNETES_PORT_443_TCP_PORT


set -x

# Get oc binary
# curl -sL "${OC_URL}" | tar -C "${binFolder}" -xzvf - oc
curl -fsSL "https://github.com/openshift-cnv/cnv-ci/tarball/release-${OCP_VERSION}" -o /tmp/cnv-ci.tgz
mkdir -p /tmp/cnv-ci
tar -xvzf /tmp/cnv-ci.tgz -C /tmp/cnv-ci --strip-components=1
cd /tmp/cnv-ci || exit 1

# Overwrite the default configuration file used for testing
# If KUBEVIRT_TESTING_CONFIGURATION is set and not empty, is has higher priority over KUBEVIRT_TESTING_CONFIGURATION_FILE
if [[ -n "${KUBEVIRT_TESTING_CONFIGURATION:-}" ]]; then
    export KUBEVIRT_TESTING_CONFIGURATION_FILE="${ARTIFACT_DIR}/kubevirt-testing-configuration.json"
    # Write inline JSON to the artifact path (avoid echo for xtrace log noise; tee preserves a traceable redirect).
    tee "${KUBEVIRT_TESTING_CONFIGURATION_FILE}" <<< "${KUBEVIRT_TESTING_CONFIGURATION}"
fi


# Run the tests
make deploy_test || exit_code=$?

set +x

if [ "${exit_code:-0}" -ne 0 ]; then
    # deploy_test failed; exit status is propagated below (xtrace is off in this block).
    if [[ -n "${CNV_WAIT_FOR_LIVE_DEBUG:-}" ]]; then
        # Hold for live debugging: positive CNV_WAIT_FOR_LIVE_DEBUG = bounded sleep; otherwise sleep inf.
        if ((${CNV_WAIT_FOR_LIVE_DEBUG} > 0)); then
            sleep "${CNV_WAIT_FOR_LIVE_DEBUG}"
        else
            sleep inf
        fi
    fi
    exit "${exit_code}"
fi

# deploy_test succeeded when execution reaches here (step outcome from exit status).
true
