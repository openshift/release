#!/bin/bash
set -e
set -o pipefail

if [ -f "${SHARED_DIR}/skip.txt" ]; then
  echo "Detected skip.txt — skipping"
  exit 0
fi

# eco-ci-cd checkout used by this step: the content baked into the step image,
# or a shallow clone of ECO_CI_CD_FORK_REPO@ECO_CI_CD_FORK_BRANCH when the
# fork override is set (rehearsal-only knob provided by the lane's ci-operator
# config; the clone lives in /tmp because /eco-ci-cd is not writable by the
# step's runtime user).
ECO_CI_CD="/eco-ci-cd"
if [[ -n "${ECO_CI_CD_FORK_REPO:-}" ]]; then
  ECO_CI_CD_FORK_BRANCH="${ECO_CI_CD_FORK_BRANCH:-main}"
  ECO_CI_CD="/tmp/eco-ci-cd-fork"
  echo "Using eco-ci-cd fork ${ECO_CI_CD_FORK_REPO}@${ECO_CI_CD_FORK_BRANCH}"
  git clone --depth 1 --branch "${ECO_CI_CD_FORK_BRANCH}" \
    "${ECO_CI_CD_FORK_REPO}" "${ECO_CI_CD}"
  # collections/ is not tracked in git (it only exists in the step image,
  # installed at /eco-ci-cd/collections by ansible-galaxy during the image
  # build), so the clone lacks it. Copy the image's collections over so
  # ansible.cfg's ./collections resolves inside the fork checkout as well.
  mkdir -p "${ECO_CI_CD}/collections"
  cp -R --no-preserve=ownership /eco-ci-cd/collections/. "${ECO_CI_CD}/collections/"
fi

echo "Copying inventory from SHARED_DIR"
mkdir -p ${ECO_CI_CD}/inventories/ocp-deployment/group_vars

cp "${SHARED_DIR}/all" ${ECO_CI_CD}/inventories/ocp-deployment/group_vars/all
cp "${SHARED_DIR}/bastions" ${ECO_CI_CD}/inventories/ocp-deployment/group_vars/bastions
cp "${SHARED_DIR}/hypervisors" ${ECO_CI_CD}/inventories/ocp-deployment/group_vars/hypervisors
cp "${SHARED_DIR}/nodes" ${ECO_CI_CD}/inventories/ocp-deployment/group_vars/nodes
cp "${SHARED_DIR}/masters" ${ECO_CI_CD}/inventories/ocp-deployment/group_vars/masters

mkdir -p ${ECO_CI_CD}/inventories/ocp-deployment/host_vars

cp "${SHARED_DIR}/bastion" ${ECO_CI_CD}/inventories/ocp-deployment/host_vars/bastion
cp "${SHARED_DIR}/hypervisor" ${ECO_CI_CD}/inventories/ocp-deployment/host_vars/hypervisor
cp "${SHARED_DIR}/master0" ${ECO_CI_CD}/inventories/ocp-deployment/host_vars/master0

KUBECONFIG_PATH="/home/telcov10n/project/generated/${CLUSTER_NAME}/auth/kubeconfig"

cd ${ECO_CI_CD}

echo "Mirroring spoke operators (VERSION=${VERSION})"
ansible-playbook ./playbooks/deploy-ocp-operators.yml \
  -i ./inventories/ocp-deployment/build-inventory.py \
  --extra-vars "kubeconfig=${KUBECONFIG_PATH} version=${VERSION} \
  disconnected=true mirror_only=true operators='$SPOKE_OPERATORS' ocp_operator_mirror_skip_internal_registry_cleanup=true \
  arch=${SPOKE_ARCH}"
