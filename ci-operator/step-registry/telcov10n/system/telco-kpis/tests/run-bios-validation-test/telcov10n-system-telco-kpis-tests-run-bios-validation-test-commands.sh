#!/bin/bash
set -euo pipefail

source "${SHARED_DIR}/telco-kpis-common-functions.sh"

# if [ -f "${SHARED_DIR}/skip.txt" ]; then
#   echo "Detected skip.txt — skipping"
#   exit 0
# fi

export_env_vars_from_json 'bios_validation' "${TEST_SETTINGS:-}" "${TEST_SETTINGS_DEFAULTS:-}"
setup_continue_on_fail
setup_debug_on_fail

main() {
    echo "Running BIOS validation test for spoke: ${SPOKE_CLUSTER}"

    setup_ansible_inventory "${SPOKE_CLUSTER}" "${HUB_CLUSTER}"

    if [[ -n "${LOCKDOWN_URI}" ]]; then
        resolve_ocp_version_from_lockdown "${LOCKDOWN_URI}"
    fi

    SPOKE_KUBECONFIG="/tmp/${SPOKE_CLUSTER}-kubeconfig"

    if [[ -z "${BIOS_PROFILE_URL}" ]]; then
        BIOS_PROFILE_URL="https://gitlab.cee.redhat.com/ocp-edge-qe/ztp-site-configs/-/raw/${SPOKE_CLUSTER}-kpi-${VERSION}/siteconfig/bios/kpi.profile"
        echo "Auto-constructed BIOS profile URL: ${BIOS_PROFILE_URL}"
    fi

    cd /eco-ci-cd

    DEBUG_FLAG=""
    if [ "${DEBUG}" = "true" ]; then
        DEBUG_FLAG="-vvv"
    fi

    echo "Running BIOS validation playbook (apply_fixes: ${APPLY_FIXES}, reboot: ${REBOOT_AFTER_APPLY})"
    local rc=0
    ansible-playbook ./playbooks/telco-kpis/run-bios-validation.yml \
        -i ./inventories/ocp-deployment/build-inventory.py \
        -e spoke_cluster="${SPOKE_CLUSTER}" \
        -e spoke_kubeconfig="${SPOKE_KUBECONFIG}" \
        -e version="${VERSION}" \
        -e bios_profile_url="${BIOS_PROFILE_URL}" \
        -e apply_fixes="${APPLY_FIXES}" \
        -e reboot_after_apply="${REBOOT_AFTER_APPLY}" \
        ${DEBUG_FLAG} || rc=$?

    echo "BIOS validation test completed for ${SPOKE_CLUSTER} (rc=${rc})"
    return "${rc}"
}

main
