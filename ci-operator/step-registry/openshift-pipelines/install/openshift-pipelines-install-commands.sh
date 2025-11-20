#!/bin/bash

set -o nounset
set -o errexit
set -o pipefail

function install_yq_if_not_exists() {
    # Install yq manually if not found in image
    echo "Checking if yq exists"
    cmd_yq="$(yq --version 2>/dev/null || true)"
    if [ -n "$cmd_yq" ]; then
        echo "yq version: $cmd_yq"
    else
        echo "Installing yq"
        mkdir -p /tmp/bin
        export PATH=$PATH:/tmp/bin/
        curl -L "https://github.com/mikefarah/yq/releases/latest/download/yq_linux_$(uname -m | sed 's/aarch64/arm64/;s/x86_64/amd64/')" \
         -o /tmp/bin/yq && chmod +x /tmp/bin/yq
    fi
}

function mapTestsForComponentReadiness() {
    if [[ $MAP_TESTS == "true" ]]; then
        results_file="${1}"
        echo "Patching Tests Result File: ${results_file}"
        if [ -f "${results_file}" ]; then
            echo "Mapping Test Suite Name To: OpenshiftPipelines-lp-interop"
            yq eval -px -ox -iI0 '.testsuites.testsuite."+@name" = "OpenshiftPipelines-lp-interop"' $results_file || echo "Warning: yq failed for ${results_file}, debug manually" >&2
        fi
    fi
}

# Archive results function
function cleanup-collect() {
    if [[ $MAP_TESTS == "true" ]]; then
      install_yq_if_not_exists
      original_results="${ARTIFACT_DIR}/original_results/"
      mkdir "${original_results}" || true
      echo "Collecting original results in ${original_results}"

      # Keep a copy of all the original Junit files before modifying them
      cp -r "${ARTIFACT_DIR}"/xml-report/ "${original_results}" || echo "Warning: couldn't copy original files" >&2

      # Remove timestamped dir to avoid spacing in filename
      mv "${ARTIFACT_DIR}"/xml-report/*/result.xml "${ARTIFACT_DIR}/xml-report/" || echo "Warning: couldn't move file to top level dir" >&2

      result_file="${ARTIFACT_DIR}/xml-report/result.xml"
      # Map tests if needed for related use cases
      mapTestsForComponentReadiness $result_file

      # Send modified file to shared dir for Data Router Reporter step
      cp "${result_file}" "${SHARED_DIR}" || echo "Warning: couldn't copy files to SHARED_DIR" >&2
    fi
}

CONSOLE_URL=$(cat $SHARED_DIR/console.url)
API_URL="https://api.${CONSOLE_URL#"https://console-openshift-console.apps."}:6443"
export CONSOLE_URL
export API_URL
export gauge_reports_dir=${ARTIFACT_DIR}
export overwrite_reports=false
export KUBECONFIG=$SHARED_DIR/kubeconfig
export GOPROXY="https://proxy.golang.org/"

# Add timeout to ignore runner connection error
gauge config runner_connection_timeout 600000 && gauge config runner_request_timeout 300000

# login for interop
if test -f ${SHARED_DIR}/kubeadmin-password
then
  OCP_CRED_USR="kubeadmin"
  export OCP_CRED_USR
  OCP_CRED_PSW="$(cat ${SHARED_DIR}/kubeadmin-password)"
  export OCP_CRED_PSW
  oc login -u kubeadmin -p "$(cat $SHARED_DIR/kubeadmin-password)" "${API_URL}" --insecure-skip-tls-verify=true
else #login for ROSA & Hypershift platforms
  eval "$(cat "${SHARED_DIR}/api.login")"
fi

echo "Running olm.spec to install operator"
CATALOG_SOURCE=redhat-operators CHANNEL=${OLM_CHANNEL} gauge run --log-level=debug --verbose --tags install specs/olm.spec || true

cleanup-collect