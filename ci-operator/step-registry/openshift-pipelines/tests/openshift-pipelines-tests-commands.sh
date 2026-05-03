#!/bin/bash
set -euxo pipefail; shopt -s inherit_errexit

typeset -a specs=()
typeset spec=''
typeset CONSOLE_URL=''
typeset API_URL=''
typeset -x GOPROXY='https://proxy.golang.org/'
typeset -x gauge_reports_dir="${ARTIFACT_DIR}"
typeset -x overwrite_reports='false'


# Map results by setting identifier prefix in tests suites names for reporting tools
# Merge original results into a single file and compress
# Send modified file to shared dir for Data Router Reporter step
if [ "${MAP_TESTS}" = "true" ]; then
    eval "$(
        curl -fsSL \
https://raw.githubusercontent.com/RedHatQE/OpenShift-LP-QE--Tools/refs/heads/main/libs/bash/ci-operator/interop/common/ExitTrap--PostProcessPrep.sh
    )"; trap '
        LP_IO__ET_PPP__NEW_TS_NAME="${REPORTPORTAL_CMP}--%s" \
            ExitTrap--PostProcessPrep junit--openshift-pipelines__tests__openshift-pipelines-tests.xml
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

gauge uninstall xml-report
gauge install xml-report --version 0.5.3
# Run gauge specs from PIPELINES_TEST_SPECS (semicolon-separated)
IFS=';' read -r -a specs <<< "${PIPELINES_TEST_SPECS:-}"
for spec in "${specs[@]}"; do
  [[ -n "${spec}" ]] || continue
  gauge run --log-level=debug --verbose --tags 'sanity & !tls' --max-retries-count=3 --retry-only 'sanity & !tls' "${spec}" || true
done

CONSOLE_URL="$(oc whoami --show-console)" \
    API_URL="$(oc whoami --show-server)" \
    gauge run --log-level=debug --verbose --tags sanity specs/operator/rbac.spec || true

true
