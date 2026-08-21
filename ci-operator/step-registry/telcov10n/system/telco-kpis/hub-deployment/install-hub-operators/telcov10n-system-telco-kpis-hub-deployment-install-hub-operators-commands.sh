#!/bin/bash

set -euo pipefail

source "${SHARED_DIR}/telco-kpis-common-functions.sh"

export_env_vars_from_json 'install_hub_operators' "${INFRA_SETTINGS:-}" "${INFRA_SETTINGS_DEFAULTS:-}"
setup_debug_on_fail

main() {
    echo "Installing hub operators on: ${HUB_CLUSTER}"

    setup_ansible_inventory "${HUB_CLUSTER}" "${HUB_CLUSTER}"

    cd /eco-ci-cd

    local kubeconfig="/home/telcov10n/project/generated/${HUB_CLUSTER}/auth/kubeconfig"

    DEBUG_FLAG="-vv"
    if [ "${DEBUG}" = "true" ]; then
        DEBUG_FLAG="-vvv"
    fi

    local extra_vars=(
        -e "kubeconfig=${kubeconfig}"
        -e "disconnected=true"
        -e "mirror_only=false"
        -e "ocp_operator_mirror_skip_internal_registry_cleanup=true"
    )

    # Do not pass version= when VERSION is empty.
    # Each Prow step runs in its own container, so deploy-sno-hub's
    # resolve_ocp_version_from_lockdown export does not carry over here.
    # When HUB_LOCKDOWN_URI is set and VERSION is empty, the deploy-ocp-operators.yml
    # lockdown_config role derives the version internally via set_fact. However,
    # Ansible --extra-vars have higher precedence than set_fact, so passing
    # -e "version=" (empty string) would silently prevent the role from setting it,
    # causing the operator install to use an empty version. Omitting the flag entirely
    # lets the role populate version correctly from the lockdown.
    if [[ -n "${VERSION:-}" ]]; then
        extra_vars+=(-e "version=${VERSION}")
    fi

    if [[ -n "${HUB_LOCKDOWN_URI:-}" ]]; then
        echo "Using hub lockdown: ${HUB_LOCKDOWN_URI}"
        extra_vars+=(-e "hub_lockdown_uri=${HUB_LOCKDOWN_URI}")
    fi

    if [[ "${GENERATE_HUB_LOCKDOWN:-false}" == "true" ]]; then
        echo "Hub lockdown generation enabled"
        extra_vars+=(-e "generate_hub_lockdown=true")
        extra_vars+=(-e "hub_cluster=${HUB_CLUSTER}")
        extra_vars+=(-e "architecture=${ARCHITECTURE:-x86_64}")
    fi

    ansible-playbook ./playbooks/telco-kpis/deploy-ocp-operators.yml \
        -i ./inventories/ocp-deployment/build-inventory.py \
        "${extra_vars[@]}" \
        ${DEBUG_FLAG}

    echo "Hub operator installation completed: ${HUB_CLUSTER}"
}

main
