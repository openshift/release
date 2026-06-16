#!/bin/bash

set -o nounset
set -o errexit
set -o pipefail

CNV_STORAGE_CLASS="${CNV_STORAGE_CLASS:-lvms-vg1}"
CNV_VOLUME_MODE="${CNV_VOLUME_MODE:-Block}"

echo "Running CNV smoke tests with storage class: ${CNV_STORAGE_CLASS}, volume mode: ${CNV_VOLUME_MODE}"

oc whoami --show-console

START_TIME=$(date "+%s")

pytest tests \
  -s \
  -o log_cli=true \
  -o cache_dir=/tmp/cache-pytest \
  -m 'smoke and not rwx_default_storage' \
  --tc-file=tests/global_config.py \
  --tc "default_storage_class:${CNV_STORAGE_CLASS}" \
  --tc "default_volume_mode:${CNV_VOLUME_MODE}" \
  --storage-class-matrix="${CNV_STORAGE_CLASS}" \
  --latest-rhel \
  --tb=native \
  --junit-xml="${ARTIFACT_DIR}/xunit_results.xml" \
  --pytest-log-file="${ARTIFACT_DIR}/pytest-tests.log" || /bin/true

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
