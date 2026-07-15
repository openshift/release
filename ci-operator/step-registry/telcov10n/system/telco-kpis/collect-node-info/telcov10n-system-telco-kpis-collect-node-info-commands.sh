#!/bin/bash
set -euo pipefail

source "${SHARED_DIR}/telco-kpis-common-functions.sh"

if [ -f "${SHARED_DIR}/skip.txt" ]; then
  echo "Detected skip.txt — skipping"
  exit 0
fi

main() {
    echo "Collecting node information for spoke: ${SPOKE_CLUSTER}"

    setup_ansible_inventory "${SPOKE_CLUSTER}" "${HUB_CLUSTER}"

    # Kubeconfig paths on the bastion (not in SHARED_DIR — Ansible SSHes to bastion)
    HUB_KUBECONFIG="/home/telcov10n/project/generated/${HUB_CLUSTER}/auth/kubeconfig"
    SPOKE_KUBECONFIG="/tmp/${SPOKE_CLUSTER}-kubeconfig"

    echo "Using kubeconfig paths on bastion:"
    echo "  Hub kubeconfig: ${HUB_KUBECONFIG}"
    echo "  Spoke kubeconfig: ${SPOKE_KUBECONFIG}"

    cd /eco-ci-cd

    echo "Running collect-node-info playbook for spoke ${SPOKE_CLUSTER}"
    DEBUG_FLAG=""
    if [ "${DEBUG}" = "true" ]; then
        DEBUG_FLAG="-vvv"
    fi
    ansible-playbook ./playbooks/telco-kpis/collect-node-info.yml \
        -i ./inventories/ocp-deployment/build-inventory.py \
        -e spoke_cluster="${SPOKE_CLUSTER}" \
        -e spoke_kubeconfig="${SPOKE_KUBECONFIG}" \
        -e skip_rebuild_image="${SKIP_REBUILD_IMAGE}" \
        ${DEBUG_FLAG}

    echo "Copy artifacts to ARTIFACT_DIR and SHARED_DIR"
    mkdir -p "${ARTIFACT_DIR}/telco-kpis"
    if [[ -f "/tmp/node-info-${SPOKE_CLUSTER}.json" ]]; then
        cp "/tmp/node-info-${SPOKE_CLUSTER}.json" "${ARTIFACT_DIR}/telco-kpis/"
        cp "/tmp/node-info-${SPOKE_CLUSTER}.json" "${SHARED_DIR}/"
    else
        echo "WARNING: node-info file not found at /tmp/node-info-${SPOKE_CLUSTER}.json"
    fi

    echo "Node information collection completed for ${SPOKE_CLUSTER}"
}

main
