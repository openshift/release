#!/bin/bash
set -e
set -o pipefail

INVENTORY_PATH="/eco-ci-cd/inventories/ocp-deployment"

# Copy inventory from SHARED_DIR
mkdir -p "${INVENTORY_PATH}/group_vars"
for group in all bastions hypervisors nodes masters workers; do
    cp "${SHARED_DIR}/${group}" "${INVENTORY_PATH}/group_vars/"
done

mkdir -p "${INVENTORY_PATH}/host_vars"
for host in bastion hypervisor master0 master1 master2 worker0 worker1; do
    cp "${SHARED_DIR}/${host}" "${INVENTORY_PATH}/host_vars/"
done

# Set kubeconfig path
KUBECONFIG_PATH="/home/telcov10n/project/generated/${CLUSTER_NAME}/auth/kubeconfig"

cd /eco-ci-cd

# Temporary: apply fix from openshift-kni/eco-ci-cd#XXX (deploy-spoke-ztp-mno
# version match fails for pre-GA releases because arch=multi nightly builds
# are named with a "-multi-" infix the hub's native-arch version never has).
# Copy the image dir to /tmp to get a writable layer, then patch just the one
# file. Remove once the PR is merged and the image is rebuilt.
ECO_CI_CD_DIR="/tmp/eco-ci-cd-patched"
cp -r /eco-ci-cd "${ECO_CI_CD_DIR}"
FIXED_FILE="playbooks/ran/deploy-spoke-ztp-mno.yaml"
curl -sf --max-time 30 \
  "https://raw.githubusercontent.com/eifrach/eco-ci-cd/fix/ztp-mno-multi-arch-release-name-match/${FIXED_FILE}" \
  -o "${ECO_CI_CD_DIR}/${FIXED_FILE}" || echo "WARNING: failed to apply multi-arch release match fix"

cd "${ECO_CI_CD_DIR}"

echo "Running ZTP deployment for spoke cluster: ${SPOKE_CLUSTER_NAME}"
ansible-playbook ./playbooks/ran/deploy-spoke-ztp-mno.yaml \
    -i ./inventories/ocp-deployment/build-inventory.py \
    --extra-vars "kubeconfig=${KUBECONFIG_PATH} \
        spoke_cluster=${SPOKE_CLUSTER_NAME} \
        ocp_version=${VERSION} \
        arch=${SPOKE_ARCH} \
        ztp_git_repo_url=${GITLAB_REPO_URL} \
        ztp_git_branch=${ZTP_GIT_BRANCH}"
