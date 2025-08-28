#!/bin/bash

set -o nounset
set -o errexit
set -o pipefail

CLUSTER_VERSION=$(oc get clusterVersion version -o jsonpath='{$.status.desired.version}')
OCP_MAJOR_MINOR=$(echo "${CLUSTER_VERSION}" | cut -d '.' -f1,2)
OCP_VERSION="${OCP_MAJOR_MINOR}"

OCS_VERSION=$(oc get csv -n openshift-storage -o json | jq -r '.items[] | select(.metadata.name | startswith("ocs-operator")).spec.version' | cut -d. -f1,2)

CLUSTER_NAME=$([[ -f "${SHARED_DIR}/CLUSTER_NAME" ]] && cat "${SHARED_DIR}/CLUSTER_NAME" || echo "cluster-name")
CLUSTER_DOMAIN="${CLUSTER_DOMAIN:-release-ci.cnv-qe.rhood.us}"
LOGS_FOLDER="${ARTIFACT_DIR}/ocs-tests"
LOGS_CONFIG="${LOGS_FOLDER}/ocs-tests-config.yaml"
CLUSTER_PATH="${ARTIFACT_DIR}/ocs-tests"

export BIN_FOLDER="${LOGS_FOLDER}/bin"

# Function to clean up folders
cleanup() {
    echo "Cleaning up..."
    [[ -d "${CLUSTER_PATH}/auth" ]] && rm -fvr "${CLUSTER_PATH}/auth"
}
# Set trap to catch EXIT and run cleanup on any exit code
trap cleanup EXIT SIGINT

#
# Remove the ACM Subscription to allow OCS interop tests full control of operators
#
OUTPUT=$(oc get subscription.apps.open-cluster-management.io -n policies openshift-plus-sub 2>/dev/null || true)
if [[ "$OUTPUT" != "" ]]; then
	oc get subscription.apps.open-cluster-management.io -n policies openshift-plus-sub -o yaml > /tmp/acm-policy-subscription-backup.yaml
	oc delete subscription.apps.open-cluster-management.io -n policies openshift-plus-sub
fi

# Overwrite OCS Test data folder
export OCSCI_DATA_DIR="${ARTIFACT_DIR}"

mkdir -p "${LOGS_FOLDER}"
mkdir -p "${CLUSTER_PATH}/auth"
mkdir -p "${CLUSTER_PATH}/data"
mkdir -p "${BIN_FOLDER}"

export PATH="${BIN_FOLDER}:${PATH}"

cp -v "${KUBECONFIG}"              "${CLUSTER_PATH}/auth/kubeconfig"
cp -v "${KUBEADMIN_PASSWORD_FILE}" "${CLUSTER_PATH}/auth/kubeadmin-password"

# Create ocs-tests config overwrite file
cat > "${LOGS_CONFIG}" << __EOF__
---
RUN:
  bin_dir: "${BIN_FOLDER}"
  log_dir: "${LOGS_FOLDER}"
REPORTING:
  default_ocs_must_gather_image: "quay.io/rhceph-dev/ocs-must-gather"
  default_ocs_must_gather_latest_tag: "latest-${ODF_VERSION_MAJOR_MINOR}"
DEPLOYMENT:
  skip_download_client: True
__EOF__


set -x
START_TIME=$(date "+%s")

run-ci --color=yes -o cache_dir=/tmp tests/ -m 'acceptance and not ui' -k '' \
  --ocsci-conf "${LOGS_CONFIG}" \
  --collect-logs \
  --ocs-version  "${OCS_VERSION}"                    \
  --ocp-version  "${OCP_VERSION}"                    \
  --cluster-path "${CLUSTER_PATH}"                   \
  --cluster-name "${CLUSTER_NAME}"                   \
  --html         "${CLUSTER_PATH}/test-results.html" \
  --junit-xml    "${CLUSTER_PATH}/junit.xml"         \
  || /bin/true

FINISH_TIME=$(date "+%s")
DIFF_TIME=$((FINISH_TIME-START_TIME))
set +x

if [[ ${DIFF_TIME} -le 1800 ]]; then
    echo ""
    echo " 🚨  The tests finished too quickly (took only: ${DIFF_TIME} sec), pausing here to give us time to debug"
    echo "  😴 😴 😴"
    sleep 7200
    exit 1
else
    echo "Finished in: ${DIFF_TIME} sec"
fi

#
# Restore the ACM subscription
#
if [[ -f /tmp/acm-policy-subscription-backup.yaml ]]; then
	oc apply -f /tmp/acm-policy-subscription-backup.yaml
fi
