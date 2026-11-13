#!/bin/bash
set -e
set -o pipefail

restore_seed_inventory() {
  mkdir -p /eco-ci-cd/inventories/ocp-deployment/group_vars
  mkdir -p /eco-ci-cd/inventories/ocp-deployment/host_vars
  cp "${SHARED_DIR}/seed-all" /eco-ci-cd/inventories/ocp-deployment/group_vars/all
  cp "${SHARED_DIR}/seed-bastions" /eco-ci-cd/inventories/ocp-deployment/group_vars/bastions
  cp "${SHARED_DIR}/seed-bastion" /eco-ci-cd/inventories/ocp-deployment/host_vars/bastion
}

mirror_seed() {
  cd /eco-ci-cd
  ansible-playbook playbooks/ran/ibu-mirror-seed-image.yml \
    -i ./inventories/ocp-deployment/build-inventory.py \
    --extra-vars "version=${VERSION} target_registry_host=${TARGET_REGISTRY_HOST}"
}

finish() {
  local rc=$?
  trap - EXIT
  rm -rf -- "$WORK_DIR" || rc=1
  if (( rc != 0 )); then
    rm -f -- "${SHARED_DIR}/ibi-seed-digest" "${SHARED_DIR}/ibi-seed-git-revision"
    echo "IBI image transfer/validation failed; target preinstall is blocked." >&2
  fi
  exit "$rc"
}

configure_ibi_mirror() {
  # Disable tracing before accessing inventory credentials.
  set +x
  set -u
  umask 077
  rm -f -- "${SHARED_DIR}/ibi-seed-digest" "${SHARED_DIR}/ibi-seed-git-revision"

  WORK_DIR=$(mktemp -d /tmp/ibi-seed-mirror.XXXXXX)
  trap finish EXIT

  cp /var/group_variables/common/all/ansible_ssh_private_key "$WORK_DIR/ssh-key"
  chmod 600 "$WORK_DIR/ssh-key"
  export ANSIBLE_PRIVATE_KEY_FILE="$WORK_DIR/ssh-key"
  export ANSIBLE_HOST_KEY_CHECKING=False
  export ANSIBLE_SSH_RETRIES=3
  export ANSIBLE_TIMEOUT=600
  export ANSIBLE_REMOTE_TEMP=/tmp
}

mirror_seed_dependencies() {
  SEED_VERSION=$(<"${SHARED_DIR}/ibi-seed-version")
  TARGET_SPOKE_NAME=$(printf '%s' "$TARGET_SPOKE_CLUSTER" | tr -d "[]'\" ")

  cd /eco-ci-cd
  ansible-playbook playbooks/ran/ibi-seed-images.yml \
    -i ./inventories/ocp-deployment/build-inventory.py \
    --extra-vars "ibi_seed_phase=mirror" \
    --extra-vars "version=${VERSION} target_registry_host=${TARGET_REGISTRY_HOST}" \
    --extra-vars "ibi_seed_version=${SEED_VERSION} ibi_mirror_registry=${MIRROR_REGISTRY}" \
    --extra-vars "ibi_seed_hub_kubeconfig=/home/telcov10n/project/generated/${CLUSTER_NAME}/auth/kubeconfig" \
    --extra-vars "ibi_target_hub_kubeconfig=/home/telcov10n/project/generated/${TARGET_CLUSTER_NAME}/auth/kubeconfig" \
    --extra-vars "ibi_ztp_git_repo=${ZTP_GIT_REPO} ibi_ztp_git_branch=${ZTP_GIT_BRANCH}" \
    --extra-vars "ibi_target_spoke=${TARGET_SPOKE_NAME}" \
    --extra-vars "ibi_shared_dir=${SHARED_DIR} ibi_report_dir=${ARTIFACT_DIR}/ibi-seed-mirror" \
    --extra-vars "ibi_seed_inventory=/eco-ci-cd/inventories/ocp-deployment/build-inventory.py" \
    --extra-vars "{\"ibi_target_inventory_files\":[\"${SHARED_DIR}/target-all\",\"${SHARED_DIR}/target-bastions\",\"${SHARED_DIR}/target-bastion\"]}"
}

main() {
  if [ -f "${SHARED_DIR}/skip.txt" ]; then
    echo "Detected skip.txt — skipping"
    return 0
  fi

  restore_seed_inventory

  # Ordinary IBU jobs retain the existing playbook and behavior.
  case "${IBI_MIRROR_SEED_DEPENDENCIES:-false}" in
    false) mirror_seed; return 0 ;;
    true) ;;
    *) echo "IBI_MIRROR_SEED_DEPENDENCIES must be true or false." >&2; return 1 ;;
  esac

  configure_ibi_mirror
  mirror_seed_dependencies
}

main "$@"
