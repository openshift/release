#!/bin/bash
set -euo pipefail

source "${SHARED_DIR}/telco-kpis-common-functions.sh"

if [ -f "${SHARED_DIR}/skip.txt" ]; then
  echo "Detected skip.txt — skipping"
  exit 0
fi

main() {
    echo "Generating report for spoke: ${SPOKE_CLUSTER}"

    setup_ansible_inventory "${SPOKE_CLUSTER}" "${HUB_CLUSTER}"

    TIMESTAMP=$(date -u +%Y%m%d-%H%M%S)

    if [[ -z "${OUTPUT_FILENAME}" ]]; then
        OUTPUT_FILENAME="telco-kpis-report-${SPOKE_CLUSTER}-${TIMESTAMP}.md"
        echo "Auto-generated output filename: ${OUTPUT_FILENAME}"
    fi

    cd /eco-ci-cd

    DEBUG_FLAG=""
    if [ "${DEBUG}" = "true" ]; then
        DEBUG_FLAG="-vvv"
    fi

    FILTER_FLAG=""
    if [[ -n "${TEST_FILTER}" ]]; then
        FILTER_FLAG="-e test_filter=${TEST_FILTER}"
    fi

    echo "Running generate-report playbook (development_mode: ${DEVELOPMENT_MODE})"
    ansible-playbook ./playbooks/telco-kpis/generate-report.yml \
        -i ./inventories/ocp-deployment/build-inventory.py \
        -e spoke_cluster="${SPOKE_CLUSTER}" \
        -e output_filename="${OUTPUT_FILENAME}" \
        -e timestamp="${TIMESTAMP}" \
        -e development_mode="${DEVELOPMENT_MODE}" \
        ${FILTER_FLAG} \
        ${DEBUG_FLAG}

    echo "Copy report artifacts to SHARED_DIR"
    if [[ -d "${ARTIFACT_DIR}/reports" ]]; then
        find "${ARTIFACT_DIR}/reports" -type f -exec cp {} "${SHARED_DIR}/" \;
    else
        echo "WARNING: reports directory not found at ${ARTIFACT_DIR}/reports"
    fi

    echo "Report generation completed for ${SPOKE_CLUSTER}"
}

main
