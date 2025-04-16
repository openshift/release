#!/bin/bash

set -o nounset
set -o errexit
set -o pipefail

# Set cluster variables
# CLUSTER_NAME=$(cat "${SHARED_DIR}/CLUSTER_NAME")
# CLUSTER_DOMAIN="${CLUSTER_DOMAIN:-release-ci.cnv-qe.rhood.us}"
BIN_FOLDER=$(mktemp -d /tmp/bin.XXXX)

# Exports
# export CLUSTER_NAME CLUSTER_DOMAIN
export PATH="${BIN_FOLDER}:${PATH}"

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
START_TIME=$(date "+%s")

# Use cnv-ci archive URL requested with Gangway API in the Prow job spec if any
CNV_CI_ARCHIVE_URL=$(
  curl -sSL https://prow.ci.openshift.org/prowjob?prowjob=${PROW_JOB_ID} \
    | sed -nr '/name: CNV_CI_ARCHIVE_URL/ { n; s|\s+value: (.*)|\1|p }'
)

# Fallback to release branch from upstream repo
if [[ -z "${CNV_CI_ARCHIVE_URL}" ]]; then
  CNV_CI_ARCHIVE_URL=https://github.com/openshift-cnv/cnv-ci/tarball/release-${OCP_VERSION}
fi

curl -L "${CNV_CI_ARCHIVE_URL}" -o /tmp/cnv-ci.tgz
mkdir -p /tmp/cnv-ci
tar -xvzf /tmp/cnv-ci.tgz -C /tmp/cnv-ci --strip-components=1
cd /tmp/cnv-ci || exit 1

# Overwrite the default configuration file used for testing
export KUBEVIRT_TESTING_CONFIGURATION_FILE='kubevirt-tier1-ocs.json'

# The default storage class used in the testing configuration file is 'ocs-storagecluster-ceph-rbd', at
# https://github.com/openshift-cnv/cnv-ci/blob/master/manifests/testing/kubevirt-tier1-ocs.json, that is kept for
# compatiblity with the current test configs at the time of writing this snippet.
# The KUBEVIRT_STORAGECLASS_NAME is set to 'ocs-storagecluster-ceph-rbd' in the 'cnv-tests-e2e-deploy' step by default too.
# Some test configurations like KubeVirt testing on ARM64 cannot use the storage class 'ocs-storagecluster-ceph-rbd' as it
# is not available on the ARM64 nodes. Users can now set the storage class name to be used in the prow test config definition,
# avoiding the need to modify these values in different repositories.
if [ "${KUBEVIRT_STORAGECLASS_RWX_NAME}" != "" ] || [ "${KUBEVIRT_STORAGECLASS_NAME}" != "" ]; then
  echo "Using storage class '${KUBEVIRT_STORAGECLASS_NAME}' and '${KUBEVIRT_STORAGECLASS_RWX_NAME}' for RWX"
  T1_CONF="{
      ${KUBEVIRT_STORAGECLASS_NAME:+\"storageClassRhel\": \"${KUBEVIRT_STORAGECLASS_NAME}\",}
      ${KUBEVIRT_STORAGECLASS_NAME:+\"storageClassWindows\": \"${KUBEVIRT_STORAGECLASS_NAME}\",}
      ${KUBEVIRT_STORAGECLASS_NAME:+\"storageRWOFileSystem\": \"${KUBEVIRT_STORAGECLASS_NAME}\",}
      ${KUBEVIRT_STORAGECLASS_NAME:+\"storageRWOBlock\": \"${KUBEVIRT_STORAGECLASS_NAME}\",}
      ${KUBEVIRT_STORAGECLASS_NAME:+\"storageSnapshot\": \"${KUBEVIRT_STORAGECLASS_NAME}\"}"
  if [ "${KUBEVIRT_STORAGECLASS_RWX_NAME}" != "" ]; then
    T1_CONF="${T1_CONF}${KUBEVIRT_STORAGECLASS_NAME:+,}
      ${KUBEVIRT_STORAGECLASS_RWX_NAME:+\"storageRWXBlock\": \"${KUBEVIRT_STORAGECLASS_RWX_NAME}\"}"
  fi
  T1_CONF="${T1_CONF}
}"
  echo "${T1_CONF}" > manifests/testing/kubevirt-tier1-ocs.json
fi

cat manifests/testing/kubevirt-tier1-ocs.json

# shellcheck disable=SC2086
make ${MAKEFILE_TARGET} || exit_code=$?

FINISH_TIME=$(date "+%s")
DIFF_TIME=$((FINISH_TIME-START_TIME))
set +x

if [[ ${DIFF_TIME} -le 720 ]]; then
    echo ""
    echo " 🚨  The tests finished too quickly (took only: ${DIFF_TIME} sec), pausing here to give us time to debug"
    echo "  😴 😴 😴"
    sleep 7200
    exit 1
else
    echo "Finished in: ${DIFF_TIME} sec"
fi

if [ "${exit_code:-0}" -ne 0 ]; then
    echo "${MAKEFILE_TARGET} failed with exit code ${exit_code}"
    exit ${exit_code}
else
    echo "${MAKEFILE_TARGET} succeeded"
fi
