#!/bin/bash
set -euo pipefail

source "${SHARED_DIR}/telco-kpis-common-functions.sh"

# if [ -f "${SHARED_DIR}/skip.txt" ]; then
#   echo "Detected skip.txt — skipping"
#   exit 0
# fi

export_env_vars_from_json 'rfc2544' "${TEST_SETTINGS:-}" "${TEST_SETTINGS_DEFAULTS:-}"
setup_continue_on_fail
setup_debug_on_fail

main() {
    echo "Running RFC2544 test for spoke: ${SPOKE_CLUSTER}"

    setup_ansible_inventory "${SPOKE_CLUSTER}" "${HUB_CLUSTER}"

    HUB_KUBECONFIG="/home/telcov10n/project/generated/${HUB_CLUSTER}/auth/kubeconfig"
    SPOKE_KUBECONFIG="/tmp/${SPOKE_CLUSTER}-kubeconfig"

    cd /eco-ci-cd

    DEBUG_FLAG=""
    if [ "${DEBUG}" = "true" ]; then
        DEBUG_FLAG="-vvv"
    fi

    echo "Running RFC2544 test (duration: ${DURATION}, frame_size: ${FRAME_SIZE}, lat_rate: ${LAT_RATE})"
    local rc=0
    ansible-playbook ./playbooks/telco-kpis/run-test.yml \
        -i ./inventories/ocp-deployment/build-inventory.py \
        -e test_name=rfc2544 \
        -e spoke_cluster="${SPOKE_CLUSTER}" \
        -e hub_kubeconfig="${HUB_KUBECONFIG}" \
        -e spoke_kubeconfig="${SPOKE_KUBECONFIG}" \
        -e duration="${DURATION}" \
        -e frame_size="${FRAME_SIZE}" \
        -e lat_rate="${LAT_RATE}" \
        -e ran_integration_repo="${RAN_INTEGRATION_REPO}" \
        -e ran_integration_branch="${RAN_INTEGRATION_BRANCH}" \
        -e spirent_config_file="${SPIRENT_CONFIG_FILE}" \
        -e throughput_threshold="${THROUGHPUT_THRESHOLD}" \
        -e max_latency_threshold="${MAX_LATENCY_THRESHOLD}" \
        -e tolerance_nines="${TOLERANCE_NINES}" \
        -e absolute_max_latency="${ABSOLUTE_MAX_LATENCY}" \
        -e skip_rebuild_image="${SKIP_REBUILD_IMAGE}" \
        ${DEBUG_FLAG} || rc=$?

    echo "Copy artifacts to SHARED_DIR for reporter step"
    local artifact_subdir="${ARTIFACT_DIR}/rfc2544-${SPOKE_CLUSTER}"
    if [[ -d "${artifact_subdir}" ]]; then
        find "${artifact_subdir}" -name "junit_*.xml" -exec cp {} "${SHARED_DIR}/" \;
    else
        echo "WARNING: artifact directory not found at ${artifact_subdir}"
    fi

    echo "RFC2544 test completed for ${SPOKE_CLUSTER} (rc=${rc})"
    return "${rc}"
}

main
