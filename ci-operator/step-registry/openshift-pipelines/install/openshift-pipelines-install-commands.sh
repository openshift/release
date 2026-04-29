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
            ExitTrap--PostProcessPrep junit--openshift-pipelines__install__openshift-pipelines-install.xml
    ' EXIT
fi

CONSOLE_URL=$(cat "${SHARED_DIR}/console.url")
API_URL="https://api.${CONSOLE_URL#"https://console-openshift-console.apps."}:6443"
export CONSOLE_URL
export API_URL
export gauge_reports_dir="${ARTIFACT_DIR}"
export overwrite_reports=false
export GOPROXY="https://proxy.golang.org/"

# Add timeout to ignore runner connection error
gauge config runner_connection_timeout 600000 && gauge config runner_request_timeout 300000

# login for interop
set +x
if test -f "${SHARED_DIR}/kubeadmin-password"
then
  OCP_CRED_USR="kubeadmin"
  export OCP_CRED_USR
  OCP_CRED_PSW="$(cat "${SHARED_DIR}/kubeadmin-password")"
  export OCP_CRED_PSW
  oc login -u kubeadmin -p "$(cat "${SHARED_DIR}/kubeadmin-password")" "${API_URL}" --insecure-skip-tls-verify=true
else #login for ROSA & Hypershift platforms
  eval "$(cat "${SHARED_DIR}/api.login")"
fi
set -x

# Install openshift-pipelines operator (olm.spec)
CATALOG_SOURCE=redhat-operators CHANNEL="${OLM_CHANNEL:-latest}" gauge run --log-level=debug --verbose --tags install specs/olm.spec || true

true
