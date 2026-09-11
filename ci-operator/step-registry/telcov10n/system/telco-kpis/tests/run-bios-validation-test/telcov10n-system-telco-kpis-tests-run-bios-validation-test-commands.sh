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

    cd /eco-ci-cd

    DEBUG_FLAG=""
    if [ "${DEBUG}" = "true" ]; then
        DEBUG_FLAG="-vvv"
    fi

    local extra_vars=()
    extra_vars+=(
        -e "spoke_cluster=${SPOKE_CLUSTER}"
        -e "spoke_kubeconfig=${SPOKE_KUBECONFIG}"
        -e "version=${VERSION}"
        -e "bios_profile_branch=${BIOS_PROFILE_BRANCH:-main}"
        -e "bios_profile_path=${BIOS_PROFILE_PATH:-dell/bios-profile.yaml}"
        -e "apply_fixes=${APPLY_FIXES}"
        -e "reboot_after_apply=${REBOOT_AFTER_APPLY}"
    )

    if [[ -n "${BIOS_PROFILE_URL:-}" ]]; then
        extra_vars+=(-e "bios_profile_url=${BIOS_PROFILE_URL}")
    elif [[ -f /var/reports-repo/git_repo_token ]]; then
        [[ $- == *x* ]] && WAS_TRACING=true || WAS_TRACING=false
        set +x
        extra_vars+=(-e "git_repo_token=$(cat /var/reports-repo/git_repo_token)")
        $WAS_TRACING && set -x
    else
        echo "WARNING: /var/reports-repo/git_repo_token not found — BIOS profile fetch will fail"
    fi

    echo "Running BIOS validation playbook (apply_fixes: ${APPLY_FIXES}, reboot: ${REBOOT_AFTER_APPLY})"
    local rc=0
    ansible-playbook ./playbooks/telco-kpis/run-bios-validation.yml \
        -i ./inventories/ocp-deployment/build-inventory.py \
        "${extra_vars[@]}" \
        ${DEBUG_FLAG} || rc=$?

    echo "BIOS validation test completed for ${SPOKE_CLUSTER} (rc=${rc})"
    return "${rc}"
}

main
