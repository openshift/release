#!/bin/bash

set -o nounset
set -o errexit
set -o pipefail

BIN_FOLDER=$(mktemp -d /tmp/bin.XXXX)
COLLECTOR_CONF_FILE="${ARTIFACT_DIR}/containerized-data-collector.yaml"
OC_URL="https://mirror.openshift.com/pub/openshift-v4/amd64/clients/ocp/latest/openshift-client-linux.tar.gz"

# Exports
export CLUSTER_NAME CLUSTER_DOMAIN
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

cat << __EOF__ | tee "${COLLECTOR_CONF_FILE}"
data_collector_base_directory: "/${ARTIFACT_DIR}/tests-collected-info"
collect_data_function: "ocp_wrapper_data_collector.data_collector.collect_data"
collect_pod_logs: true
__EOF__

set -x
START_TIME=$(date "+%s")

# Get oc binary
curl -sL "${OC_URL}" | tar -C "${BIN_FOLDER}" -xzvf - oc

oc whoami --show-console

ACCESS_TOKEN=$(head -1 "${CLUSTER_PROFILE_DIR}/bitwarden-client-secret.txt")
ORGANIZATION_ID=$(head -1 "${CLUSTER_PROFILE_DIR}/bitwarden-org-id")

uv run --verbose --cache-dir /tmp/uv-cache pytest  \
  --pytest-log-file="${ARTIFACT_DIR}/tests.log" \
  --data-collector="${COLLECTOR_CONF_FILE}" \
  --junitxml "${ARTIFACT_DIR}/junit_results.xml" \
  --html=${ARTIFACT_DIR}/report.html --self-contained-html \
  --tc-file=tests/global_config.py \
  --tc-format=python \
  --tc=check_http_server_connectivity:false \
  --tc default_storage_class:ocs-storagecluster-ceph-rbd \
  --tc default_volume_mode:Block \
  --latest-rhel \
  --tb=native \
  --storage-class-matrix=ocs-storagecluster-ceph-rbd \
  -o log_cli=true \
  -o cache_dir=/tmp \
  --tc=hco_subscription:kubevirt-hyperconverged \
  -m smoke || /bin/true

FINISH_TIME=$(date "+%s")
DIFF_TIME=$((FINISH_TIME-START_TIME))
set +x

if [[ ${DIFF_TIME} -le 600 ]]; then
    echo ""
    echo " 🚨  The tests finished too quickly (took only: ${DIFF_TIME} sec), pausing here to give us time to debug"
    echo "  😴 😴 😴"
    sleep 7200
    exit 1
else
    echo "Finished in: ${DIFF_TIME} sec"
fi
