#!/bin/bash

set -euxo pipefail
shopt -s inherit_errexit

CLUSTER_VERSION=$(oc get clusterVersion version -o jsonpath='{$.status.desired.version}')
OCP_MAJOR_MINOR=$(echo "${CLUSTER_VERSION}" | cut -d '.' -f1,2)
OCP_VERSION="${OCP_MAJOR_MINOR}"

OCS_VERSION=$(
  oc get csv -n openshift-storage -o json 2>/dev/null |
    jq -r '
      [ .items[] | select(.metadata.name | test("^(ocs-(client-)?|odf-)operator")) ] |
      first | .spec.version // empty
    ' | cut -d. -f1,2
) || true
if [[ -z "${OCS_VERSION}" ]]; then
    # ERROR: OCS_VERSION not set or CSV lookup failed; list openshift-storage CSVs after failure (namespace may be missing).
    oc get csv -n openshift-storage -o custom-columns=NAME:.metadata.name,VERSION:.spec.version,PHASE:.status.phase 2>&1 || true
    exit 1
fi

CLUSTER_NAME=$([[ -f "${SHARED_DIR}/CLUSTER_NAME" ]] && cat "${SHARED_DIR}/CLUSTER_NAME" || echo "cluster-name")
CLUSTER_DOMAIN="${CLUSTER_DOMAIN:-release-ci.cnv-qe.rhood.us}"
LOGS_FOLDER="${ARTIFACT_DIR}/ocs-tests"
LOGS_CONFIG="${LOGS_FOLDER}/ocs-tests-config.yaml"
CLUSTER_PATH="${ARTIFACT_DIR}/ocs-tests"

export BIN_FOLDER="${LOGS_FOLDER}/bin"

# Function to clean up folders
cleanup() {
    # Tear down local auth copy created for run-ci.
    [[ -d "${CLUSTER_PATH}/auth" ]] && rm -rf "${CLUSTER_PATH}/auth"
}

if [ "${MAP_TESTS}" = "true" ]; then
    # Avoid conflicts with the older versioned yq from the image:
    # Write /tmp/bin/yq as a tiny script (#!/bin/sh; exit 1), so yq --version fails and ExitTrap EnsureReqs downloads latest yq (replacing the stub).
    eval "$(
        curl -fsSL https://raw.githubusercontent.com/RedHatQE/OpenShift-LP-QE--Tools/refs/heads/main/libs/bash/ci-operator/interop/common/ExitTrap--PostProcessPrep.sh
    )"
    trap '
        cleanup
        mkdir -p /tmp/bin
        printf "%s\n" "#!/bin/sh" "exit 1" > /tmp/bin/yq && chmod +x /tmp/bin/yq
        PATH="/tmp/bin:${PATH}"
        LP_IO__ET_PPP__NEW_TS_NAME="${DR__RP__CR_COMP_NAME}--%s" \
            ExitTrap--PostProcessPrep junit--odf__interop-tests__ocs-tests__interop-tests-ocs-tests.xml
    ' EXIT
else
    trap 'cleanup' EXIT
fi

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

if [ -s "${KUBECONFIG}" ]; then
    oc whoami
    cp -v "${KUBECONFIG}"              "${CLUSTER_PATH}/auth/kubeconfig"
    cp -v "${KUBEADMIN_PASSWORD_FILE}" "${CLUSTER_PATH}/auth/kubeadmin-password"
else #login for ROSA & Hypershift platforms
    (set +x; eval "$(cat "${SHARED_DIR}/api.login")")
fi

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

# Append ENV_DATA in ocs-tests config file for vsphere platform
if [[ -f "${SHARED_DIR}/vsphere_context.sh" ]]; then
    declare vsphere_datacenter
    declare vsphere_datastore
    declare vsphere_cluster
    source "${SHARED_DIR}/vsphere_context.sh"
    source "${SHARED_DIR}/govc.sh"

    cat >> "${LOGS_CONFIG}" << __APPENDED_ENV_DATA__
ENV_DATA:
  platform: "vsphere"
  vsphere_user: "${GOVC_USERNAME}"
  vsphere_password: "${GOVC_PASSWORD}"
  vsphere_datacenter: "${vsphere_datacenter}"
  vsphere_cluster: "${vsphere_cluster}"
  vsphere_datastore: "${vsphere_datastore}"
__APPENDED_ENV_DATA__
fi

EXTRA_ARGS=""
if [[ "${DISABLE_ENVIRONMENT_CHECKER}" == "true" ]]; then
    EXTRA_ARGS="--disable-environment-checker"
fi

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
  ${EXTRA_ARGS} \
  || /bin/true

FINISH_TIME=$(date "+%s")
DIFF_TIME=$((FINISH_TIME-START_TIME))

if [[ ${DIFF_TIME} -le 1800 ]]; then
    # ERROR: tests finished too quickly (DIFF_TIME sec <= 1800)
    exit 1
fi

#
# Restore the ACM subscription
#
if [[ -f /tmp/acm-policy-subscription-backup.yaml ]]; then
	oc apply -f /tmp/acm-policy-subscription-backup.yaml
fi

true
