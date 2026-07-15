#!/bin/bash
set -euo pipefail

source "${SHARED_DIR}/telco-kpis-common-functions.sh"

if [ -f "${SHARED_DIR}/skip.txt" ]; then
  echo "Detected skip.txt — skipping"
  exit 0
fi

main() {
    echo "Running RDS compare test for spoke: ${SPOKE_CLUSTER}"

    setup_ansible_inventory "${SPOKE_CLUSTER}" "${HUB_CLUSTER}"

    SPOKE_KUBECONFIG="/tmp/${SPOKE_CLUSTER}-kubeconfig"

    EFFECTIVE_REFERENCE_BRANCH="${REFERENCE_BRANCH}"
    if [[ -z "${EFFECTIVE_REFERENCE_BRANCH}" ]]; then
        EFFECTIVE_REFERENCE_BRANCH="release-${VERSION}"
        echo "Auto-constructed reference branch: ${EFFECTIVE_REFERENCE_BRANCH}"
    fi

    cd /eco-ci-cd

    DEBUG_FLAG=""
    if [ "${DEBUG}" = "true" ]; then
        DEBUG_FLAG="-vvv"
    fi

    echo "Running RDS compare (version: ${VERSION}, branch: ${EFFECTIVE_REFERENCE_BRANCH}, baseline: ${BASELINE})"
    ansible-playbook ./playbooks/telco-kpis/run-rds-compare.yml \
        -i ./inventories/ocp-deployment/build-inventory.py \
        -e spoke_cluster="${SPOKE_CLUSTER}" \
        -e spoke_kubeconfig="${SPOKE_KUBECONFIG}" \
        -e version="${VERSION}" \
        -e reference_branch="${EFFECTIVE_REFERENCE_BRANCH}" \
        -e reference_repo_url="${REFERENCE_REPO_URL}" \
        -e metadata_relpath="${METADATA_RELPATH}" \
        -e baseline="${BASELINE}" \
        ${DEBUG_FLAG}

    echo "Copy artifacts to SHARED_DIR for reporter step"
    local artifact_subdir="${ARTIFACT_DIR}/rds_compare-${SPOKE_CLUSTER}"
    if [[ -d "${artifact_subdir}" ]]; then
        find "${artifact_subdir}" -name "junit_*.xml" -exec cp {} "${SHARED_DIR}/" \;
    else
        echo "WARNING: artifact directory not found at ${artifact_subdir}"
    fi

    echo "RDS compare test completed for ${SPOKE_CLUSTER}"
}

main
