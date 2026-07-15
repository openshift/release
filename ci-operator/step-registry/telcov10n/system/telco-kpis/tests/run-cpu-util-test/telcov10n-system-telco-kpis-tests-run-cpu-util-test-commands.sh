#!/bin/bash
set -euo pipefail

source "${SHARED_DIR}/telco-kpis-common-functions.sh"

# if [ -f "${SHARED_DIR}/skip.txt" ]; then
#   echo "Detected skip.txt — skipping"
#   exit 0
# fi

export_env_vars_from_json 'cpu_util' "${TEST_SETTINGS:-}" "${TEST_SETTINGS_DEFAULTS:-}"
setup_continue_on_fail

main() {
    echo "Running cpu_util test for spoke: ${SPOKE_CLUSTER}"

    setup_ansible_inventory "${SPOKE_CLUSTER}" "${HUB_CLUSTER}"

    HUB_KUBECONFIG="/home/telcov10n/project/generated/${HUB_CLUSTER}/auth/kubeconfig"
    SPOKE_KUBECONFIG="/tmp/${SPOKE_CLUSTER}-kubeconfig"

    TEST_NAME="cpu_util"
    if [ "${BASELINE}" = "true" ]; then
        TEST_NAME="cpu_util_baseline"
    fi

    cd /eco-ci-cd

    DEBUG_FLAG=""
    if [ "${DEBUG}" = "true" ]; then
        DEBUG_FLAG="-vvv"
    fi

    echo "Running cpu_util test (baseline: ${BASELINE}, duration: ${DURATION}, test_name: ${TEST_NAME})"
    ansible-playbook ./playbooks/telco-kpis/run-test.yml \
        -i ./inventories/ocp-deployment/build-inventory.py \
        -e test_name="${TEST_NAME}" \
        -e spoke_cluster="${SPOKE_CLUSTER}" \
        -e hub_kubeconfig="${HUB_KUBECONFIG}" \
        -e spoke_kubeconfig="${SPOKE_KUBECONFIG}" \
        -e duration="${DURATION}" \
        -e baseline="${BASELINE}" \
        -e skip_rebuild_image="${SKIP_REBUILD_IMAGE}" \
        ${DEBUG_FLAG}

    echo "Copy artifacts to SHARED_DIR for reporter step"
    local artifact_subdir="${ARTIFACT_DIR}/${TEST_NAME}-${SPOKE_CLUSTER}"
    if [[ -d "${artifact_subdir}" ]]; then
        find "${artifact_subdir}" -name "junit_*.xml" -exec cp {} "${SHARED_DIR}/" \;
    else
        echo "WARNING: artifact directory not found at ${artifact_subdir}"
    fi

    echo "cpu_util test completed for ${SPOKE_CLUSTER}"
}

main
