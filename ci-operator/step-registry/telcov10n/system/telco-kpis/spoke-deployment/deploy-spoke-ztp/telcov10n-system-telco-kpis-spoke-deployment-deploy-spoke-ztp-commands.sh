#!/bin/bash

set -euo pipefail

source "${SHARED_DIR}/telco-kpis-common-functions.sh"

export_env_vars_from_json 'deploy_spoke_ztp' "${INFRA_SETTINGS:-}" "${INFRA_SETTINGS_DEFAULTS:-}"
setup_debug_on_fail

main() {
    echo "Deploying spoke ${SPOKE_CLUSTER} via ZTP from hub ${HUB_CLUSTER}"

    setup_ansible_inventory "${SPOKE_CLUSTER}" "${HUB_CLUSTER}"

    cd /eco-ci-cd

    local kubeconfig="/home/telcov10n/project/generated/${HUB_CLUSTER}/auth/kubeconfig"

    local DEBUG_FLAG="-vv"
    if [[ "${DEBUG:-false}" == "true" ]]; then
        DEBUG_FLAG="-vvv"
    fi

    local ztp_branch="${ZTP_GIT_BRANCH:-}"
    if [[ -z "${ztp_branch}" ]]; then
        ztp_branch="${SPOKE_CLUSTER}-kpi-${VERSION}"
        echo "Auto-generated ZTP branch: ${ztp_branch}"
    fi

    local extra_vars=(
        -e "kubeconfig=${kubeconfig}"
        -e "spoke_cluster=${SPOKE_CLUSTER}"
        -e "ocp_version=${VERSION}"
        -e "force_cleanup=${FORCE_CLEANUP:-false}"
        -e "ztp_git_repo_url=${ZTP_GIT_REPO}"
        -e "ztp_git_branch=${ztp_branch}"
        -e "ztp_clusters_git_path=${ZTP_CLUSTERS_PATH}"
        -e "ztp_policies_git_path=${ZTP_POLICIES_PATH}"
        -e "masters_secret_name=masters-bmc-secret"
        -e "bmc_secret_name=baremetal-bmc-secret"
    )

    if [[ -n "${OCP_RELEASE_IMAGE:-}" ]]; then
        extra_vars+=(-e "ocp_release_image=${OCP_RELEASE_IMAGE}")
    fi

    ansible-playbook ./playbooks/ran/deploy-spoke-ztp.yml \
        -i ./inventories/ocp-deployment/build-inventory.py \
        "${extra_vars[@]}" \
        ${DEBUG_FLAG}

    echo "Spoke ${SPOKE_CLUSTER} ZTP deployment completed"
}

main
