#!/bin/bash
set -euo pipefail

source "${SHARED_DIR}/telco-kpis-common-functions.sh"

# if [ -f "${SHARED_DIR}/skip.txt" ]; then
#   echo "Detected skip.txt — skipping"
#   exit 0
# fi

export_env_vars_from_json 'ztp_ai_deployment_time' "${TEST_SETTINGS:-}" "${TEST_SETTINGS_DEFAULTS:-}"
setup_continue_on_fail
setup_debug_on_fail

main() {
    echo "Running ZTP AI deployment time test for spoke: ${SPOKE_CLUSTER}"

    setup_ansible_inventory "${SPOKE_CLUSTER}" "${HUB_CLUSTER}"

    # Kubeconfig path on the bastion (Ansible SSHes to bastion to query ACM resources)
    HUB_KUBECONFIG="/home/telcov10n/project/generated/${HUB_CLUSTER}/auth/kubeconfig"

    echo "Using hub kubeconfig on bastion: ${HUB_KUBECONFIG}"

    cd /eco-ci-cd

    DEBUG_FLAG=""
    if [ "${DEBUG}" = "true" ]; then
        DEBUG_FLAG="-vvv"
    fi

    echo "Running ztp-ai-deployment-time playbook (threshold: ${THRESHOLD_DURATION})"
    ansible-playbook ./playbooks/telco-kpis/ztp-ai-deployment-time.yml \
        -i ./inventories/ocp-deployment/build-inventory.py \
        -e test_name=ztp_ai_deployment_time \
        -e spoke_cluster="${SPOKE_CLUSTER}" \
        -e hub_cluster="${HUB_CLUSTER}" \
        -e hub_kubeconfig="${HUB_KUBECONFIG}" \
        -e threshold_duration="${THRESHOLD_DURATION}" \
        ${DEBUG_FLAG}

    echo "Copy JUnit XML to SHARED_DIR for reporter step"
    local artifact_subdir="${ARTIFACT_DIR}/ztp_ai_deployment_time-${SPOKE_CLUSTER}"
    if [[ -d "${artifact_subdir}" ]]; then
        find "${artifact_subdir}" -name "junit_*.xml" -exec cp {} "${SHARED_DIR}/" \;
    else
        echo "WARNING: artifact directory not found at ${artifact_subdir}"
    fi

    echo "ZTP AI deployment time test completed for ${SPOKE_CLUSTER}"
}

main
