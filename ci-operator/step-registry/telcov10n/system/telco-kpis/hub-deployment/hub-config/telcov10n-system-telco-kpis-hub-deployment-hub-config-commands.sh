#!/bin/bash

set -euo pipefail

source "${SHARED_DIR}/telco-kpis-common-functions.sh"

export_env_vars_from_json 'hub_config' "${INFRA_SETTINGS:-}" "${INFRA_SETTINGS_DEFAULTS:-}"

main() {
    echo "Configuring hub cluster: ${HUB_CLUSTER}"

    setup_ansible_inventory "${HUB_CLUSTER}" "${HUB_CLUSTER}"

    cd /eco-ci-cd

    local kubeconfig="/home/telcov10n/project/generated/${HUB_CLUSTER}/auth/kubeconfig"

    DEBUG_FLAG="-vv"
    if [ "${DEBUG}" = "true" ]; then
        DEBUG_FLAG="-vvv"
    fi

    echo "=== Step 1/4: Configure LVM storage ==="
    ansible-playbook ./playbooks/ran/hub-sno-configure-lvm-storage.yml \
        -i ./inventories/ocp-deployment/build-inventory.py \
        -e "kubeconfig=${kubeconfig}" \
        ${DEBUG_FLAG}

    echo "=== Step 2/4: Configure ACM ==="
    ansible-playbook ./playbooks/ran/hub-sno-configure-acm.yml \
        -i ./inventories/ocp-deployment/build-inventory.py \
        -e "kubeconfig=${kubeconfig}" \
        -e "ocp_version=${VERSION}" \
        ${DEBUG_FLAG}

    echo "=== Step 3/4: Configure kustomize plugin ==="
    ansible-playbook ./playbooks/ran/hub-sno-configure-kustomize-plugin.yml \
        -i ./inventories/ocp-deployment/build-inventory.py \
        -e "kubeconfig=${kubeconfig}" \
        -e "ocp_version=${VERSION}" \
        ${DEBUG_FLAG}

    echo "=== Step 4/4: Configure GitOps ==="
    ansible-playbook ./playbooks/ran/hub-sno-configure-gitops.yml \
        -i ./inventories/ocp-deployment/build-inventory.py \
        -e "kubeconfig=${kubeconfig}" \
        -e "gitlab_repo_url=${GITLAB_REPO_URL}" \
        -e "gitlab_repo_branch=${GITLAB_REPO_BRANCH}" \
        ${DEBUG_FLAG}

    echo "Hub configuration completed: ${HUB_CLUSTER}"
}

main
