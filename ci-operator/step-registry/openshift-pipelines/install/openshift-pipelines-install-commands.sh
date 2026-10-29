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
        LP_IO__ET_PPP__NEW_TS_NAME="${DR__RP__CR_COMP_NAME}--%s" \
            ExitTrap--PostProcessPrep junit--openshift-pipelines__install__openshift-pipelines-install.xml
    ' EXIT
fi

# Add timeout to ignore runner connection error
gauge config runner_connection_timeout 600000 && gauge config runner_request_timeout 300000

# login for interop
if [ -s "${KUBECONFIG}" ]; then
    oc whoami
else #login for ROSA & Hypershift platforms
    (set +x; eval "$(cat "${SHARED_DIR}/api.login")")
fi

# Install openshift-pipelines operator (olm.spec)
CONSOLE_URL="$(oc whoami --show-console)" \
    API_URL="$(oc whoami --show-server)" \
    CATALOG_SOURCE=redhat-operators \
    CHANNEL="${OLM_CHANNEL:-latest}" \
    gauge_reports_dir="${ARTIFACT_DIR}" \
    overwrite_reports=false \
    gauge run --log-level=debug --verbose --tags install specs/olm.spec

true
