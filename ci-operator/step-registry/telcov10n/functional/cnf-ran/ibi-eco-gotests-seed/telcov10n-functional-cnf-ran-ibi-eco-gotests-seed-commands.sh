#!/bin/bash
set +x
set -e
set -o pipefail

OCP_DEPLOYMENT_INVENTORY_PATH="/eco-ci-cd/inventories/ocp-deployment"
CNF_INVENTORY_PATH="/eco-ci-cd/inventories/cnf"

cleanup() {
  rm -rf -- "$ARTIFACT_WORK"
}

restore_seed_inventory() {
  # Copy inventory from SHARED_DIR (processed by earlier hub-deploy step)
  echo "=== Copying inventory for seed hub ${CLUSTER_NAME} from SHARED_DIR ==="

  mkdir -p "${OCP_DEPLOYMENT_INVENTORY_PATH}/group_vars"
  mkdir -p "${OCP_DEPLOYMENT_INVENTORY_PATH}/host_vars"

  cp "${SHARED_DIR}/all"       "${OCP_DEPLOYMENT_INVENTORY_PATH}/group_vars/all"
  cp "${SHARED_DIR}/bastions"  "${OCP_DEPLOYMENT_INVENTORY_PATH}/group_vars/bastions"
  cp "${SHARED_DIR}/nodes"     "${OCP_DEPLOYMENT_INVENTORY_PATH}/group_vars/nodes"
  cp "${SHARED_DIR}/masters"   "${OCP_DEPLOYMENT_INVENTORY_PATH}/group_vars/masters"
  cp "${SHARED_DIR}/bastion"   "${OCP_DEPLOYMENT_INVENTORY_PATH}/host_vars/bastion"

  mkdir -p "${CNF_INVENTORY_PATH}/group_vars"
  mkdir -p "${CNF_INVENTORY_PATH}/host_vars"

  cp "${SHARED_DIR}/bastions" "${CNF_INVENTORY_PATH}/group_vars/bastions.yaml"
  cp "${SHARED_DIR}/all"      "${CNF_INVENTORY_PATH}/group_vars/all.yaml"
  cp "${SHARED_DIR}/bastion"  "${CNF_INVENTORY_PATH}/host_vars/bastion.yaml"

  echo "Inventory copied from SHARED_DIR"
}

check_seed_kubeconfig() {
  echo "=== Step 1: Check saved seed kubeconfig on the seed bastion ==="
  cd /eco-ci-cd
  SEED_SPOKE_KUBECONFIG="/tmp/${SEED_SPOKE_CLUSTER}-kubeconfig"
  # Preparation must run before ACM detachment. Do not fetch the hub Secret here.
  if ! ansible bastion \
    -i "${CNF_INVENTORY_PATH}/switch-config.yaml" \
    -m ansible.builtin.shell \
    -a "test -r '${SEED_SPOKE_KUBECONFIG}' && test -s '${SEED_SPOKE_KUBECONFIG}'"; then
    echo "Seed kubeconfig is missing, empty, or unreadable on the seed bastion. Run ibi-seed-prepare before ibu-prune-argocd-apps." >&2
    exit 1
  fi
}

prepare_seedgeneration() {
  echo "=== Step 2: Generate eco-gotests IBI seedgeneration script ==="

  ECO_GOTESTS_ENV_VARS="-e ECO_CNF_RAN_SKIP_TLS_VERIFY=true"
  ECO_GOTESTS_ENV_VARS+=" -e ECO_LCA_IBGU_SEED_IMAGE=${MIRROR_REGISTRY}/ibu/seed:${VERSION}"
  ECO_GOTESTS_ENV_VARS+=" -e ECO_LCA_IBU_CNF_KUBECONFIG_TARGET_SNO=/kubeconfig/kubeconfig"

  ansible-playbook playbooks/deploy-run-eco-gotests.yaml \
    -i "${CNF_INVENTORY_PATH}/switch-config.yaml" \
    --extra-vars "kubeconfig=${SEED_SPOKE_KUBECONFIG}" \
    --extra-vars "features=${ECO_GOTESTS_FEATURES}" \
    --extra-vars 'labels=!no-container' \
    --extra-vars 'eco_worker_label=""' \
    --extra-vars 'eco_cnf_core_net_switch_user=""' \
    --extra-vars 'eco_cnf_core_net_switch_pass=""' \
    --extra-vars 'eco_gotests_tag=latest' \
    --extra-vars "additional_test_env_variables=\"${ECO_GOTESTS_ENV_VARS}\""

  # Preparation above removes the old test directory before creating this launcher.
  printf '%s\n' /tmp/eco_gotests/report > "${SHARED_DIR}/ibi-rp-seedgen-dir"
}

prepare_capture_access() {
  ARTIFACT_WORK=$(mktemp -d /tmp/ibi-seed-artifacts.XXXXXX)
  trap cleanup EXIT
  cp /var/group_variables/common/all/ansible_ssh_private_key "$ARTIFACT_WORK/ssh-key"
  chmod 600 "$ARTIFACT_WORK/ssh-key"

  BASTION_IP=$(grep -oP '(?<=ansible_host: ).*' "${CNF_INVENTORY_PATH}/host_vars/bastion.yaml" | sed "s/'//g")
  BASTION_USER=$(grep -oP '(?<=ansible_user: ).*' "${CNF_INVENTORY_PATH}/group_vars/all.yaml" | sed "s/'//g")
  [[ "$BASTION_IP" =~ ^[a-zA-Z0-9.-]+$ && "$BASTION_USER" =~ ^[a-zA-Z0-9_-]+$ ]]
  [[ "$CLUSTER_NAME" =~ ^[a-z0-9-]+$ && "$SEED_SPOKE_CLUSTER" =~ ^[a-z0-9-]+$ ]]
}

capture_catalogs() {
  # Capture floating catalog identities before seed generation changes the seed.
  rm -f -- "${SHARED_DIR}/ibi-seed-catalogs.json"
  SEED_VERSION=$(<"${SHARED_DIR}/ibi-seed-version")
  ansible-playbook playbooks/ran/ibi-seed-images.yml \
    -i "${CNF_INVENTORY_PATH}/switch-config.yaml" \
    --extra-vars "ibi_seed_phase=capture" \
    --extra-vars "ibi_seed_kubeconfig=${SEED_SPOKE_KUBECONFIG}" \
    --extra-vars "ibi_hub_kubeconfig=/home/telcov10n/project/generated/${CLUSTER_NAME}/auth/kubeconfig" \
    --extra-vars "ibi_mirror_registry=${MIRROR_REGISTRY}" \
    --extra-vars "ibi_seed_version=${SEED_VERSION}" \
    --extra-vars "ibi_catalogs_output=${SHARED_DIR}/ibi-seed-catalogs.json" \
    --extra-vars "ansible_private_key_file=${ARTIFACT_WORK}/ssh-key" \
    --extra-vars 'ansible_ssh_common_args="-o BatchMode=yes -o ConnectTimeout=30 -o ServerAliveInterval=30 -o ServerAliveCountMax=6 -o StrictHostKeyChecking=no -o UserKnownHostsFile=/dev/null"'
}

run_seedgeneration() {
  echo "=== Step 2b: Run seedgeneration ==="
  ansible-playbook playbooks/ran/ibu-run-seedgeneration.yml \
    -i "${CNF_INVENTORY_PATH}/switch-config.yaml" \
    --extra-vars "spoke_cluster=${SEED_SPOKE_CLUSTER}" \
    --extra-vars "kubeconfig=${SEED_SPOKE_KUBECONFIG}"
}

collect_reports() {
  echo "Gather artifacts from bastion"
  mkdir -p "${ARTIFACT_DIR}/junit_eco_gotests"
  scp -r -o StrictHostKeyChecking=no -o UserKnownHostsFile=/dev/null \
    -i "$ARTIFACT_WORK/ssh-key" \
    "${BASTION_USER}@${BASTION_IP}:/tmp/eco_gotests/report/*.xml" \
    "${ARTIFACT_DIR}/junit_eco_gotests/" || true
}

main() {
  echo "Checking if the job should be skipped..."
  if [ -f "${SHARED_DIR}/skip.txt" ]; then
    echo "Detected skip.txt file — skipping the job"
    return 0
  fi

  export ANSIBLE_REMOTE_TEMP=/tmp

  echo "=== IBI Seed eco-gotests Configuration ==="
  echo "SEED_SPOKE_CLUSTER=${SEED_SPOKE_CLUSTER}"
  echo "CLUSTER_NAME=${CLUSTER_NAME}"
  echo "ECO_GOTESTS_FEATURES=${ECO_GOTESTS_FEATURES}"
  echo "MIRROR_REGISTRY=${MIRROR_REGISTRY}"
  echo "VERSION=${VERSION}"
  echo ""
  restore_seed_inventory
  check_seed_kubeconfig
  prepare_seedgeneration
  prepare_capture_access
  capture_catalogs
  run_seedgeneration
  collect_reports

  echo "=== IBI Seed Eco-Gotests Complete ==="
  echo "Seed image: ${MIRROR_REGISTRY}/ibu/seed:${VERSION}"
  echo "Seed generation completed; the image is ready to mirror to the target registry."
}

main "$@"
