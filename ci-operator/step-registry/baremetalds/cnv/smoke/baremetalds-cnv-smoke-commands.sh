#!/bin/bash

set -o nounset
set -o errexit
set -o pipefail

CNV_STORAGE_CLASS="${CNV_STORAGE_CLASS:-lvms-vg1}"
CNV_VOLUME_MODE="${CNV_VOLUME_MODE:-Filesystem}"

echo "Running CNV smoke tests with storage class: ${CNV_STORAGE_CLASS}"

oc whoami --show-console

COLLECTOR_CONF_FILE="${ARTIFACT_DIR}/containerized-data-collector.yaml"
cat << __EOF__ | tee "${COLLECTOR_CONF_FILE}"
data_collector_base_directory: "/${ARTIFACT_DIR}/tests-collected-info"
collect_data_function: "ocp_wrapper_data_collector.data_collector.collect_data"
collect_pod_logs: true
__EOF__

START_TIME=$(date "+%s")

poetry run pytest tests \
  --pytest-log-file="${ARTIFACT_DIR}/pytest.log" \
  --data-collector="${COLLECTOR_CONF_FILE}" \
  --junit-xml="${ARTIFACT_DIR}/junit_results.xml" \
  --tc-file=tests/global_config.py \
  --tc-format=python \
  --tc=check_http_server_connectivity:false \
  --tc "default_storage_class:${CNV_STORAGE_CLASS}" \
  --tc "default_volume_mode:${CNV_VOLUME_MODE}" \
  --latest-rhel \
  --tb=native \
  --storage-class-matrix="${CNV_STORAGE_CLASS}" \
  -o log_cli=true \
  -m smoke || /bin/true

FINISH_TIME=$(date "+%s")
DIFF_TIME=$((FINISH_TIME - START_TIME))

if [[ ${DIFF_TIME} -le 600 ]]; then
    echo ""
    echo "The tests finished too quickly (took only: ${DIFF_TIME} sec), pausing here to give time to debug"
    sleep 7200
    exit 1
else
    echo "Finished in: ${DIFF_TIME} sec"
fi
