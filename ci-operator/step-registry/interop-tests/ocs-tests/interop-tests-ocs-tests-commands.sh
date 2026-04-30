#!/bin/bash
set -euxo pipefail; shopt -s inherit_errexit

# --- Variables ---
typeset logsFolder="${ARTIFACT_DIR}/ocs-tests"
typeset logsConfig="${logsFolder}/ocs-tests-config.yaml"
typeset clusterPath="${ARTIFACT_DIR}/ocs-tests"
typeset binFolder="${logsFolder}/bin"
typeset ocsVersion
typeset ocpVersion
typeset clusterName
export PATH
export OCSCI_DATA_DIR 	# Overrides OCS test framework default test data location

ocsVersion=$(oc get csv -n openshift-storage -o json | jq -r '.items[] | select(.metadata.name | startswith("ocs-operator")).spec.version' | cut -d. -f1,2)
ocpVersion=$(oc get clusterVersion version -o jsonpath='{$.status.desired.version}' | cut -d '.' -f1,2)
clusterName=$([[ -f "${SHARED_DIR}/CLUSTER_NAME" ]] && cat "${SHARED_DIR}/CLUSTER_NAME" || echo "cluster-name")
PATH="${binFolder}:${PATH}"
OCSCI_DATA_DIR="${ARTIFACT_DIR}"

mkdir -p "${logsFolder}" "${clusterPath}/auth" "${clusterPath}/data" "${binFolder}"

cp -v "${KUBECONFIG}"              "${clusterPath}/auth/kubeconfig"
cp -v "${KUBEADMIN_PASSWORD_FILE}" "${clusterPath}/auth/kubeadmin-password"

# Function to clean up folders
cleanup() {
    : "Cleaning up..."
    [[ -d "${clusterPath}/auth" ]] && rm -fvr "${clusterPath}/auth"
}
# Set trap to catch EXIT and run cleanup on any exit code
trap cleanup EXIT SIGINT

function mapTestsForComponentReadiness() {
    if [[ $MAP_TESTS == "true" ]]; then
        typeset results_file="${1}"
        : "Patching Tests Result File: ${results_file}"
        if [ -f "${results_file}" ]; then
            export REPORTPORTAL_CMP
            : "Mapping Test Site Name To: ${REPORTPORTAL_CMP}"
            yq eval -px -ox -iI0 '.testsuites.testsuite.+@name=env(REPORTPORTAL_CMP)' $results_file || echo "Warning: yq failed for ${results_file}, debug manually" >&2
        fi
    fi
}

# Create ocs-tests config overwrite file
cat > "${logsConfig}" << __EOF__
---
RUN:
  bin_dir: "${binFolder}"
  log_dir: "${logsFolder}"
REPORTING:
  ocs_must_gather_image: "registry.redhat.io/odf4/odf-must-gather-rhel9"
  ocp_must_gather_image: "registry.redhat.io/openshift4/ose-must-gather:latest"
  tarball_mg_logs: False
  delete_packed_mg_logs: False
DEPLOYMENT:
  skip_download_client: True
__EOF__

set +x
# Append ENV_DATA in ocs-tests config file for vsphere platform
if [[ -f "${SHARED_DIR}/vsphere_context.sh" ]]; then
    typeset vsphere_datacenter
    typeset vsphere_cluster
    typeset vsphere_datastore
    source "${SHARED_DIR}/vsphere_context.sh"
    source "${SHARED_DIR}/govc.sh"

    cat >> "${logsConfig}" << __APPENDED_ENV_DATA__
ENV_DATA:
  platform: "vsphere"
  vsphere_user: "${GOVC_USERNAME}"
  vsphere_password: "${GOVC_PASSWORD}"
  vsphere_datacenter: "${vsphere_datacenter}"
  vsphere_cluster: "${vsphere_cluster}"
  vsphere_datastore: "${vsphere_datastore}"
__APPENDED_ENV_DATA__
fi
set -x

# Remove the ACM Subscription to allow OCS interop tests full control of operators
if oc get subscription.apps.open-cluster-management.io -n policies openshift-plus-sub 2>/dev/null; then
    oc get subscription.apps.open-cluster-management.io -n policies openshift-plus-sub -o yaml > /tmp/acm-policy-subscription-backup.yaml
    oc delete subscription.apps.open-cluster-management.io -n policies openshift-plus-sub
fi

# Record start time for test duration check
typeset START_TIME END_TIME DIFF_TIME
START_TIME=$(date +%s)

run-ci --color=yes -o cache_dir=/tmp tests/ -m 'acceptance and not ui' -k '' \
  --ocsci-conf "${logsConfig}" \
  --collect-logs-on-success-run \
  --ocs-version  "${ocsVersion}"                    \
  --ocp-version  "${ocpVersion}"                    \
  --cluster-path "${clusterPath}"                   \
  --cluster-name "${clusterName}"                   \
  --html         "${clusterPath}/test-results.html" \
  --junit-xml    "${clusterPath}/junit.xml"         \
  || /bin/true

# Calculate test duration
END_TIME=$(date +%s)
DIFF_TIME=$((END_TIME - START_TIME))

# Check if tests finished too quickly (might indicate a problem)
if [[ ${DIFF_TIME} -le 1800 ]]; then
    : ""
    : " 🚨  The tests finished too quickly (took only: ${DIFF_TIME} sec), pausing here to give us time to debug"
    : "  😴 😴 😴"
    sleep 7200
    exit 1
else
    echo "Finished in: ${DIFF_TIME} sec"
fi

# Map tests if needed for related use cases
mapTestsForComponentReadiness "${clusterPath}/junit.xml"

# Send junit file to shared dir for Data Router Reporter step
cp "${clusterPath}/junit.xml" "${SHARED_DIR}"

# Restore the ACM subscription
if [[ -f /tmp/acm-policy-subscription-backup.yaml ]]; then
    oc apply -f /tmp/acm-policy-subscription-backup.yaml
fi

true
