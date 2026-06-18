#!/bin/bash

set -o nounset
set -o errexit
set -o pipefail

CNV_STORAGE_CLASS="${CNV_STORAGE_CLASS:-lvms-vg1}"
CNV_VOLUME_MODE="${CNV_VOLUME_MODE:-Block}"

export UV_CACHE_DIR=/tmp/uv-cache
export HOME=/tmp

BW_PATH="${BW_PATH:-/bw}"
set +x
ACCESS_TOKEN=$(head -1 "${BW_PATH}"/bitwarden-client-secret)
ORGANIZATION_ID=$(head -1 "${BW_PATH}"/bitwarden-org-id)
ARTIFACTORY_USER=$(head -1 "${BW_PATH}"/artifactory-user || printf ci-read-only-user)
ARTIFACTORY_TOKEN=$(head -1 "${BW_PATH}"/artifactory-token)
ARTIFACTORY_SERVER=$(head -1 "${BW_PATH}"/artifactory-server)
set -x
export ACCESS_TOKEN ORGANIZATION_ID ARTIFACTORY_USER ARTIFACTORY_TOKEN ARTIFACTORY_SERVER

unset KUBERNETES_SERVICE_PORT_HTTPS
unset KUBERNETES_SERVICE_PORT
unset KUBERNETES_PORT_443_TCP
unset KUBERNETES_PORT_443_TCP_PROTO
unset KUBERNETES_PORT_443_TCP_ADDR
unset KUBERNETES_SERVICE_HOST
unset KUBERNETES_PORT
unset KUBERNETES_PORT_443_TCP_PORT

if test -f "${SHARED_DIR}/proxy-conf.sh"; then
  source "${SHARED_DIR}/proxy-conf.sh"
  NO_PROXY="${NO_PROXY},bitwarden.com,bitwarden.eu"
  no_proxy="${no_proxy},bitwarden.com,bitwarden.eu"
  export NO_PROXY no_proxy
fi

export KUBECONFIG=${SHARED_DIR}/kubeconfig

echo "Running CNV smoke tests with storage class: ${CNV_STORAGE_CLASS}, volume mode: ${CNV_VOLUME_MODE}"

oc whoami --show-console

START_TIME=$(date "+%s")

export OPENSHIFT_PYTHON_WRAPPER_LOG_FILE="${ARTIFACT_DIR}/openshift_python_wrapper.log"

rc=0
uv --verbose --cache-dir /tmp/uv-cache \
  run pytest tests \
  -s \
  -o log_cli=true \
  -o cache_dir=/tmp/pytest-cache \
  -m 'smoke and not rwx_default_storage' \
  --tc-file=tests/global_config_lvms.py \
  --tc "default_storage_class:${CNV_STORAGE_CLASS}" \
  --tc "default_volume_mode:${CNV_VOLUME_MODE}" \
  --storage-class-matrix="${CNV_STORAGE_CLASS}" \
  --data-collector --data-collector-output-dir="${ARTIFACT_DIR}/" \
  --latest-rhel \
  --tb=native \
  --junitxml="${ARTIFACT_DIR}/xunit_results.xml" \
  --pytest-log-file="${ARTIFACT_DIR}/pytest-tests.log" || rc=$?

FINISH_TIME=$(date "+%s")
DIFF_TIME=$((FINISH_TIME - START_TIME))

if [[ ${DIFF_TIME} -le 600 ]]; then
    echo ""
    echo "The tests finished too quickly (took only: ${DIFF_TIME} sec), pausing here to give time to debug"
    sleep 7200
fi

exit "${rc}"
