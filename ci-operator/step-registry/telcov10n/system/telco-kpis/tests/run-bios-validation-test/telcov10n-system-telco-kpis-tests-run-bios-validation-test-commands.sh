#!/bin/bash
set -euo pipefail

source "${SHARED_DIR}/telco-kpis-common-functions.sh"

# if [ -f "${SHARED_DIR}/skip.txt" ]; then
#   echo "Detected skip.txt — skipping"
#   exit 0
# fi

export_env_vars_from_json 'bios_validation' "${TEST_SETTINGS:-}" "${TEST_SETTINGS_DEFAULTS:-}"
setup_continue_on_fail

main() {
    echo "Running BIOS validation test for spoke: ${SPOKE_CLUSTER}"

    setup_ansible_inventory "${SPOKE_CLUSTER}" "${HUB_CLUSTER}"

    SPOKE_KUBECONFIG="/tmp/${SPOKE_CLUSTER}-kubeconfig"

    if [[ -z "${BIOS_PROFILE_URL}" ]]; then
        BIOS_PROFILE_URL="https://gitlab.cee.redhat.com/ccardeno/ztp-site-configs-ci/-/raw/telco-kpis/siteconfigs/${VERSION}/${SPOKE_CLUSTER}/bios/kpi.profile"
        echo "Auto-constructed BIOS profile URL: ${BIOS_PROFILE_URL}"
    fi

    cd /eco-ci-cd

    DEBUG_FLAG=""
    if [ "${DEBUG}" = "true" ]; then
        DEBUG_FLAG="-vvv"
    fi

    echo "Running BIOS validation playbook (apply_fixes: ${APPLY_FIXES}, reboot: ${REBOOT_AFTER_APPLY})"
    ansible-playbook ./playbooks/telco-kpis/run-bios-validation.yml \
        -i ./inventories/ocp-deployment/build-inventory.py \
        -e spoke_cluster="${SPOKE_CLUSTER}" \
        -e spoke_kubeconfig="${SPOKE_KUBECONFIG}" \
        -e version="${VERSION}" \
        -e bios_profile_url="${BIOS_PROFILE_URL}" \
        -e apply_fixes="${APPLY_FIXES}" \
        -e reboot_after_apply="${REBOOT_AFTER_APPLY}" \
        ${DEBUG_FLAG}

    echo "Copy artifacts to ARTIFACT_DIR and SHARED_DIR"
    local artifact_subdir="${ARTIFACT_DIR}/bios_validation-${SPOKE_CLUSTER}"
    if [[ -d "${artifact_subdir}" ]]; then
        find "${artifact_subdir}" -name "junit_*.xml" -exec cp {} "${SHARED_DIR}/" \;
    else
        echo "WARNING: artifact directory not found at ${artifact_subdir}"
    fi

    echo "BIOS validation test completed for ${SPOKE_CLUSTER}"
}

main
