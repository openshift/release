#!/bin/bash

set -o nounset
set -o errexit
set -o pipefail

function cleanup_omr_proof_temp_files() {
  local -a temp_files=()

  if [[ -n "${omr_repository_tmp:-}" ]]; then
    temp_files+=("${omr_repository_tmp}")
  fi
  if [[ -n "${omr_cli_tmp:-}" ]]; then
    temp_files+=("${omr_cli_tmp}")
  fi
  if [[ -n "${omr_completed_tmp:-}" ]]; then
    temp_files+=("${omr_completed_tmp}")
  fi

  if (( ${#temp_files[@]} == 0 )); then
    return 0
  fi

  if ! rm -f -- "${temp_files[@]}"; then
    echo "Failed to remove temporary OMR proof files."
    return 1
  fi

  omr_repository_tmp=""
  omr_cli_tmp=""
  omr_completed_tmp=""
}

function cleanup_uncommitted_omr_proofs() {
  local cleanup_failed=false

  if ! cleanup_omr_proof_temp_files; then
    cleanup_failed=true
  fi

  # A nonempty final timestamp is the sole commit marker for the proof set.
  if [[ "${omr_proof_publication_started:-false}" == true && ! -s "${SHARED_DIR}/omr_mirror_completed_at" ]]; then
    if ! rm -f -- \
      "${SHARED_DIR}/omr_mirror_repository" \
      "${SHARED_DIR}/omr_mirrored_cli_image"; then
      echo "Failed to remove uncommitted OMR proof files."
      cleanup_failed=true
    fi
  fi

  [[ "${cleanup_failed}" == false ]]
}

function cleanup_local_signature_temp_files() {
  local -a temp_files=()

  if [[ -n "${signature_release_info_tmp}" ]]; then
    temp_files+=("${signature_release_info_tmp}")
  fi
  if [[ -n "${signature_mappings_tmp}" ]]; then
    temp_files+=("${signature_mappings_tmp}")
  fi

  if (( ${#temp_files[@]} == 0 )); then
    return 0
  fi

  if ! rm -f -- "${temp_files[@]}"; then
    echo "Failed to remove local release signature temporary files."
    return 1
  fi

  signature_release_info_tmp=""
  signature_mappings_tmp=""
}

function cleanup_on_exit() {
  local original_status="$1"
  local -a remote_cleanup_files=()
  local remote_cleanup_file
  local remote_cleanup_command="rm -f --"

  if [[ "${original_status}" == 0 ]]; then
    EXIT_CODE=0
  fi

  cleanup_uncommitted_omr_proofs || true
  cleanup_local_signature_temp_files || true

  if [[ -n "${new_pull_secret:-}" ]]; then
    rm -f -- "${new_pull_secret}" || true
  fi

  if [[ -n "${remote_pull_secret:-}" && -n "${ssh_options:-}" && -n "${BASTION_SSH_USER:-}" && -n "${BASTION_IP:-}" ]]; then
    remote_cleanup_files+=("${remote_pull_secret}")
  fi
  if [[ -n "${remote_signature_mappings_tmp}" && -n "${ssh_options:-}" && -n "${BASTION_SSH_USER:-}" && -n "${BASTION_IP:-}" ]]; then
    remote_cleanup_files+=("${remote_signature_mappings_tmp}")
  fi

  if (( ${#remote_cleanup_files[@]} > 0 )); then
    for remote_cleanup_file in "${remote_cleanup_files[@]}"; do
      remote_cleanup_command+=" '${remote_cleanup_file}'"
    done
    # shellcheck disable=SC2090
    ssh ${ssh_options} -o ConnectTimeout=10 ${BASTION_SSH_USER}@${BASTION_IP} \
      "${remote_cleanup_command}" >/dev/null 2>&1 || true
  fi

  echo "${EXIT_CODE}" > "${SHARED_DIR}/install-pre-config-status.txt"
}

function terminate_on_term() {
  trap - TERM
  exit 143
}

signature_release_info_tmp=""
signature_mappings_tmp=""
remote_signature_mappings_tmp=""

# save the exit code for junit xml file generated in step gather-must-gather
# pre configuration steps before running installation, exit code 100 if failed,
# save to install-pre-config-status.txt
# post check steps after cluster installation, exit code 101 if failed,
# save to install-post-check-status.txt
EXIT_CODE=100
trap 'cleanup_on_exit "$?"' EXIT
trap terminate_on_term TERM

if [[ "${MIRROR_BIN}" != "oc-adm" ]]; then
  echo "users specifically do not use oc-adm to run mirror"
  exit 0
fi

if [[ "${MIRROR_IN_BASTION}" != "yes" ]]; then
  echo "users are going to mirror images from local, skip this step."
  exit 0
fi

if [[ "${MIRROR_RELEASE_SIGNATURES:-no}" == "yes" ]]; then
  omr_repository_tmp=""
  omr_cli_tmp=""
  omr_completed_tmp=""
  omr_proof_publication_started=true
  if ! cleanup_omr_proof_temp_files; then
    echo "Failed to remove temporary OMR proof files."
    exit 1
  fi
  if ! rm -f -- \
    "${SHARED_DIR}/omr_mirror_completed_at" \
    "${SHARED_DIR}/omr_mirror_repository" \
    "${SHARED_DIR}/omr_mirrored_cli_image"; then
    echo "Failed to remove stale OMR proof files."
    exit 1
  fi
fi

export HOME="${HOME:-/tmp/home}"
export XDG_RUNTIME_DIR="${HOME}/run"
export REGISTRY_AUTH_PREFERENCE=podman # TODO: remove later, used for migrating oc from docker to podman
mkdir -p "${XDG_RUNTIME_DIR}"

function run_command() {
    local CMD="$1"
    echo "Running command: ${CMD}"
    eval "${CMD}"
}

mirror_output="${SHARED_DIR}/mirror_output"
pull_secret_filename="new_pull_secret"
new_pull_secret="${SHARED_DIR}/${pull_secret_filename}"
remote_pull_secret="/tmp/${pull_secret_filename}"
install_config_mirror_patch="${SHARED_DIR}/install-config-mirror.yaml.patch"
cluster_mirror_conf_file="${SHARED_DIR}/local_registry_mirror_file.yaml"

# private mirror registry host
# <public_dns>:<port>
if [ ! -f "${SHARED_DIR}/mirror_registry_url" ]; then
    echo "File ${SHARED_DIR}/mirror_registry_url does not exist."
    exit 1
fi
MIRROR_REGISTRY_HOST=$(head -n 1 "${SHARED_DIR}/mirror_registry_url")
echo "MIRROR_REGISTRY_HOST: $MIRROR_REGISTRY_HOST"

if [[ -n "${CUSTOM_OPENSHIFT_INSTALL_RELEASE_IMAGE_OVERRIDE:-}" ]]; then
  echo "Overwrite OPENSHIFT_INSTALL_RELEASE_IMAGE_OVERRIDE to ${CUSTOM_OPENSHIFT_INSTALL_RELEASE_IMAGE_OVERRIDE} for cluster installation"
  export OPENSHIFT_INSTALL_RELEASE_IMAGE_OVERRIDE=${CUSTOM_OPENSHIFT_INSTALL_RELEASE_IMAGE_OVERRIDE}
fi

echo "OPENSHIFT_INSTALL_RELEASE_IMAGE_OVERRIDE: ${OPENSHIFT_INSTALL_RELEASE_IMAGE_OVERRIDE}"

# since ci-operator gives steps KUBECONFIG pointing to cluster under test under some circumstances,
# unset KUBECONFIG to ensure this step always interact with the build farm.
unset KUBECONFIG
oc registry login

readable_version=$(oc adm release info "${OPENSHIFT_INSTALL_RELEASE_IMAGE_OVERRIDE}" -o jsonpath='{.metadata.version}')
echo "readable_version: $readable_version"

# target release
target_release_image="${MIRROR_REGISTRY_HOST}/${OPENSHIFT_INSTALL_RELEASE_IMAGE_OVERRIDE#*/}"
target_release_image_repo="${target_release_image%:*}"
target_release_image_repo="${target_release_image_repo%@sha256*}"
# ensure mirror release image by tag name, refer to https://github.com/openshift/oc/pull/1331
target_release_image="${target_release_image_repo}:${readable_version}"

echo "target_release_image: $target_release_image"
echo "target_release_image_repo: $target_release_image_repo"

# combine custom registry credential and default pull secret
runtime_registry_creds="${SHARED_DIR}/mirror_registry_creds"
vault_registry_creds="/var/run/vault/mirror-registry/registry_creds"
if [[ -s "${runtime_registry_creds}" ]]; then
    registry_creds_file="${runtime_registry_creds}"
    echo "Using runtime mirror registry credentials from SHARED_DIR."
else
    registry_creds_file="${vault_registry_creds}"
    echo "Using the configured mirror registry credential fallback."
fi
registry_cred=$(head -n 1 "${registry_creds_file}" | base64 -w 0)
original_umask=$(umask)
umask 077
if ! rm -f -- "${new_pull_secret}"; then
  umask "${original_umask}"
  echo "Failed to remove the previous merged pull secret."
  exit 1
fi
if ! jq --argjson a "{\"${MIRROR_REGISTRY_HOST}\": {\"auth\": \"$registry_cred\"}}" \
  '.auths |= . + $a' "${CLUSTER_PROFILE_DIR}/pull-secret" > "${new_pull_secret}"; then
  umask "${original_umask}"
  echo "Failed to create the merged pull secret."
  exit 1
fi
umask "${original_umask}"
if ! chmod 0600 "${new_pull_secret}"; then
  echo "Failed to secure the merged pull secret."
  exit 1
fi
oc registry login --to "${new_pull_secret}"

# Ensure our UID, which is randomly generated, is in /etc/passwd. This is required
# to be able to SSH.
if ! whoami &> /dev/null; then
    if [[ -w /etc/passwd ]]; then
        echo "${USER_NAME:-default}:x:$(id -u):0:${USER_NAME:-default} user:${HOME}:/sbin/nologin" >> /etc/passwd
    else
        echo "/etc/passwd is not writeable, and user matching this uid is not found."
        exit 1
    fi
fi

SSH_PRIV_KEY_PATH=${CLUSTER_PROFILE_DIR}/ssh-privatekey
BASTION_IP=$(<"${SHARED_DIR}/bastion_private_address")
if [[ -s "${SHARED_DIR}/bastion_public_address" ]]; then
    BASTION_IP=$(<"${SHARED_DIR}/bastion_public_address")
fi
BASTION_SSH_USER=$(<"${SHARED_DIR}/bastion_ssh_user")

# shellcheck disable=SC2089
ssh_options="-o UserKnownHostsFile=/dev/null -o IdentityFile=${SSH_PRIV_KEY_PATH} -o StrictHostKeyChecking=no"
echo "copy pull secret from local to the remote host"
# shellcheck disable=SC2090
if ! scp ${ssh_options} "${new_pull_secret}" ${BASTION_SSH_USER}@${BASTION_IP}:${remote_pull_secret}; then
    echo "Failed to copy the pull secret to the remote host."
    exit 1
fi
# shellcheck disable=SC2090
if ! ssh ${ssh_options} ${BASTION_SSH_USER}@${BASTION_IP} "chmod 0600 '${remote_pull_secret}'"; then
    echo "Failed to secure the pull secret on the remote host."
    exit 1
fi

mirror_crd_type='icsp'
regex_keyword_1="imageContentSources"
if [[ "${ENABLE_IDMS}" == "yes" ]]; then
    mirror_crd_type='idms'
    regex_keyword_1="imageDigestSources"
fi

# set the release mirror args
args=(
    --from="${OPENSHIFT_INSTALL_RELEASE_IMAGE_OVERRIDE}"
    --to-release-image="${target_release_image}"
    --to="${target_release_image_repo}"
    --insecure=true
)

run_command "which oc && oc version --client"
OC_BIN="oc"
remote_oc_bin="/tmp/oc"
if ssh ${ssh_options} ${BASTION_SSH_USER}@${BASTION_IP} "which oc && oc version --client"; then
    echo "use the installed oc in the remote host"
else
    local_oc_bin=$(which oc)
    echo "copy ${local_oc_bin} from local to the remote host"
    # shellcheck disable=SC2090
    scp ${ssh_options} "${local_oc_bin}" ${BASTION_SSH_USER}@${BASTION_IP}:${remote_oc_bin}
    OC_BIN="${remote_oc_bin}"
    # Note, if hit "/lib64/libc.so.6: version `GLIBC_2.33' not found" issue, that means the
    # remote host OS is out of date, maybe need to use a newer bastion image to launch.
    ssh ${ssh_options} ${BASTION_SSH_USER}@${BASTION_IP} "${OC_BIN} version --client"
fi

# check whether the oc command supports the extra options and add them to the args array.
# shellcheck disable=SC2090
if ssh ${ssh_options} ${BASTION_SSH_USER}@${BASTION_IP} "${OC_BIN} adm release mirror -h | grep -q -- --keep-manifest-list"; then
    echo "Adding --keep-manifest-list to the mirror command."
    args+=(--keep-manifest-list=true)
else
    echo "This oc version does not support --keep-manifest-list, skip it."
fi

# shellcheck disable=SC2090
if ssh ${ssh_options} ${BASTION_SSH_USER}@${BASTION_IP} "${OC_BIN} adm release mirror -h | grep -q -- --print-mirror-instructions"; then
    echo "Adding --print-mirror-instructions to the mirror command."
    args+=(--print-mirror-instructions="${mirror_crd_type}")
else
    echo "This oc version does not support --print-mirror-instructions, skip it."
fi

# mirror images in bastion host, which will increase mirror upload speed
cmd="${OC_BIN} adm release -a '${remote_pull_secret}' mirror ${args[*]}"
cmd_with_ssh="ssh ${ssh_options} ${BASTION_SSH_USER}@${BASTION_IP} \
              \"${cmd}\" | tee ${mirror_output}"
echo "Remote Command: ${cmd}"

MAX_ATTEMPTS=5
ATTEMPTS=1
SUCCESS=false
while [ "${SUCCESS}" = false ] && (( ATTEMPTS <= MAX_ATTEMPTS )); do
  echo "Mirroring images attempt ${ATTEMPTS}/${MAX_ATTEMPTS}"

  # shellcheck disable=SC2090
  if run_command "$cmd_with_ssh"; then
    echo "Mirroring images was successful in attempt $ATTEMPTS"
    SUCCESS=true
  else
    echo "Mirroring images attempt $ATTEMPTS failed."
    if (( ATTEMPTS >= MAX_ATTEMPTS )); then
      break
    fi
    echo "Trying image mirroring again in 120 seconds."
    sleep 120
    ((ATTEMPTS += 1))
  fi
done

if [ $SUCCESS = false ]; then
  echo "Mirroring test images failed after $ATTEMPTS attempts, exiting ..."
  exit 1
fi

function cleanup_release_signature_files() {
  local cleanup_failed=false

  if ! cleanup_local_signature_temp_files; then
    cleanup_failed=true
  fi

  if [[ -n "${remote_signature_mappings_tmp}" ]]; then
    # shellcheck disable=SC2090
    if ssh ${ssh_options} ${BASTION_SSH_USER}@${BASTION_IP} "rm -f -- '${remote_signature_mappings_tmp}'"; then
      remote_signature_mappings_tmp=""
    else
      echo "Failed to remove the remote release signature mappings file."
      cleanup_failed=true
    fi
  fi

  [[ "${cleanup_failed}" == false ]]
}

function mirror_release_signatures() {
  local cli_image
  local cli_digest
  local expected_mapping_count
  local mapping_count
  local attempt=1
  local success=false
  local completed_at

  remote_signature_mappings_tmp="/tmp/release-signature-mappings-${UNIQUE_HASH}"

  if ! signature_release_info_tmp=$(mktemp "/tmp/release-info-${UNIQUE_HASH}.XXXXXX"); then
    echo "Failed to create a local release info file."
    return 1
  fi

  if ! signature_mappings_tmp=$(mktemp "/tmp/release-signature-mappings-${UNIQUE_HASH}.XXXXXX"); then
    echo "Failed to create a local release signature mappings file."
    if ! cleanup_release_signature_files; then
      echo "Release signature temporary file cleanup failed."
    fi
    return 1
  fi

  echo "Collecting release image information for signature mirroring."
  # shellcheck disable=SC2090
  if ! ssh ${ssh_options} ${BASTION_SSH_USER}@${BASTION_IP} \
    "${OC_BIN} adm release info -a '${remote_pull_secret}' --include-images -o json '${OPENSHIFT_INSTALL_RELEASE_IMAGE_OVERRIDE}'" \
    > "${signature_release_info_tmp}"; then
    echo "Failed to collect release image information on the bastion."
    if ! cleanup_release_signature_files; then
      echo "Release signature temporary file cleanup failed."
    fi
    return 1
  fi

  if [[ ! -s "${signature_release_info_tmp}" ]]; then
    echo "Release image information from the bastion is empty."
    if ! cleanup_release_signature_files; then
      echo "Release signature temporary file cleanup failed."
    fi
    return 1
  fi

  if ! jq -e '
    (.digest | type == "string" and test("^sha256:[a-f0-9]{64}$"))
    and
    (
      [
        .references.spec.tags[]?.from.name
        | select(startswith("quay.io/openshift-release-dev/ocp-v4.0-art-dev@"))
      ]
      | all(test("^quay.io/openshift-release-dev/ocp-v4\\.0-art-dev@sha256:[a-f0-9]{64}$"))
    )
  ' "${signature_release_info_tmp}" > /dev/null; then
    echo "Release image information contains an invalid payload or component digest."
    if ! cleanup_release_signature_files; then
      echo "Release signature temporary file cleanup failed."
    fi
    return 1
  fi

  if ! expected_mapping_count=$(jq -er '
    (
      [
        .references.spec.tags[]?.from.name
        | select(startswith("quay.io/openshift-release-dev/ocp-v4.0-art-dev@"))
      ]
      | unique
      | length
    ) + 1
  ' "${signature_release_info_tmp}"); then
    echo "Failed to count the expected release signature mappings."
    if ! cleanup_release_signature_files; then
      echo "Release signature temporary file cleanup failed."
    fi
    return 1
  fi

  if ! jq -r --arg target "${target_release_image_repo}" '
    [
      ("quay.io/openshift-release-dev/ocp-release@" + .digest),
      (.references.spec.tags[]?.from.name | select(startswith("quay.io/openshift-release-dev/ocp-v4.0-art-dev@sha256:")))
    ]
    | unique[]
    | capture("^(?<repository>.+)@(?<algorithm>sha256):(?<digest>[a-f0-9]{64})$")
    | "\(.repository):\(.algorithm)-\(.digest).sig=\($target):\(.algorithm)-\(.digest).sig"
  ' "${signature_release_info_tmp}" > "${signature_mappings_tmp}"; then
    echo "Failed to generate release signature mappings."
    if ! cleanup_release_signature_files; then
      echo "Release signature temporary file cleanup failed."
    fi
    return 1
  fi

  if [[ ! -s "${signature_mappings_tmp}" ]]; then
    echo "Release signature mappings are empty."
    if ! cleanup_release_signature_files; then
      echo "Release signature temporary file cleanup failed."
    fi
    return 1
  fi

  if ! mapping_count=$(wc -l < "${signature_mappings_tmp}"); then
    echo "Failed to count the generated release signature mappings."
    if ! cleanup_release_signature_files; then
      echo "Release signature temporary file cleanup failed."
    fi
    return 1
  fi

  if (( mapping_count != expected_mapping_count )); then
    echo "Generated ${mapping_count} release signature mappings, expected ${expected_mapping_count}."
    if ! cleanup_release_signature_files; then
      echo "Release signature temporary file cleanup failed."
    fi
    return 1
  fi

  if ! cli_image=$(jq -er 'first(.references.spec.tags[]? | select(.name == "cli") | .from.name)' "${signature_release_info_tmp}"); then
    echo "The release image information does not contain a cli image."
    if ! cleanup_release_signature_files; then
      echo "Release signature temporary file cleanup failed."
    fi
    return 1
  fi

  if [[ "${cli_image}" =~ ^.+@(sha256:[a-f0-9]{64})$ ]]; then
    cli_digest="${BASH_REMATCH[1]}"
  else
    echo "The release cli image does not contain a valid sha256 digest."
    if ! cleanup_release_signature_files; then
      echo "Release signature temporary file cleanup failed."
    fi
    return 1
  fi

  echo "Copying release signature mappings to the bastion."
  # shellcheck disable=SC2090
  if ! scp ${ssh_options} "${signature_mappings_tmp}" ${BASTION_SSH_USER}@${BASTION_IP}:${remote_signature_mappings_tmp}; then
    echo "Failed to copy release signature mappings to the bastion."
    if ! cleanup_release_signature_files; then
      echo "Release signature temporary file cleanup failed."
    fi
    return 1
  fi

  while [[ "${success}" == false ]] && (( attempt <= MAX_ATTEMPTS )); do
    echo "Mirroring release signatures attempt ${attempt}/${MAX_ATTEMPTS}"

    # shellcheck disable=SC2090
    if ssh ${ssh_options} ${BASTION_SSH_USER}@${BASTION_IP} \
      "${OC_BIN} image mirror --filename='${remote_signature_mappings_tmp}' --insecure=true --registry-config='${remote_pull_secret}'"; then
      echo "Mirroring release signatures was successful in attempt ${attempt}"
      success=true
    else
      echo "Mirroring release signatures attempt ${attempt} failed."
      if (( attempt >= MAX_ATTEMPTS )); then
        break
      fi
      echo "Trying release signature mirroring again in 120 seconds."
      if ! sleep 120; then
        echo "Interrupted while waiting to retry release signature mirroring."
        if ! cleanup_release_signature_files; then
          echo "Release signature temporary file cleanup failed."
        fi
        return 1
      fi
      ((attempt += 1))
    fi
  done

  if [[ "${success}" == false ]]; then
    echo "Mirroring release signatures failed after ${attempt} attempts."
    if ! cleanup_release_signature_files; then
      echo "Release signature temporary file cleanup failed."
    fi
    return 1
  fi

  if ! cleanup_release_signature_files; then
    echo "Release signature temporary file cleanup failed."
    return 1
  fi

  if ! completed_at=$(date -u +%Y-%m-%dT%H:%M:%SZ); then
    echo "Failed to determine the release signature mirror completion time."
    return 1
  fi

  if ! omr_repository_tmp=$(mktemp "${SHARED_DIR}/.omr_mirror_repository.XXXXXX"); then
    echo "Failed to create the temporary OMR mirror repository proof file."
    return 1
  fi
  if ! omr_cli_tmp=$(mktemp "${SHARED_DIR}/.omr_mirrored_cli_image.XXXXXX"); then
    echo "Failed to create the temporary OMR mirrored cli image proof file."
    cleanup_uncommitted_omr_proofs || true
    return 1
  fi
  if ! omr_completed_tmp=$(mktemp "${SHARED_DIR}/.omr_mirror_completed_at.XXXXXX"); then
    echo "Failed to create the temporary OMR mirror completion proof file."
    cleanup_uncommitted_omr_proofs || true
    return 1
  fi

  if ! printf '%s\n' "${target_release_image_repo}" > "${omr_repository_tmp}"; then
    echo "Failed to write the temporary OMR mirror repository proof file."
    cleanup_uncommitted_omr_proofs || true
    return 1
  fi
  if ! printf '%s@%s\n' "${target_release_image_repo}" "${cli_digest}" > "${omr_cli_tmp}"; then
    echo "Failed to write the temporary OMR mirrored cli image proof file."
    cleanup_uncommitted_omr_proofs || true
    return 1
  fi
  if ! printf '%s\n' "${completed_at}" > "${omr_completed_tmp}"; then
    echo "Failed to write the temporary OMR mirror completion proof file."
    cleanup_uncommitted_omr_proofs || true
    return 1
  fi
  if ! chmod 0644 "${omr_repository_tmp}" "${omr_cli_tmp}" "${omr_completed_tmp}"; then
    echo "Failed to set OMR proof file permissions."
    cleanup_uncommitted_omr_proofs || true
    return 1
  fi

  if ! mv -f -- "${omr_repository_tmp}" "${SHARED_DIR}/omr_mirror_repository"; then
    echo "Failed to publish the OMR mirror repository proof file."
    cleanup_uncommitted_omr_proofs || true
    return 1
  fi
  omr_repository_tmp=""
  if ! mv -f -- "${omr_cli_tmp}" "${SHARED_DIR}/omr_mirrored_cli_image"; then
    echo "Failed to publish the OMR mirrored cli image proof file."
    cleanup_uncommitted_omr_proofs || true
    return 1
  fi
  omr_cli_tmp=""
  # Publish the commit marker last so cleanup can distinguish partial proof sets.
  if ! mv -f -- "${omr_completed_tmp}" "${SHARED_DIR}/omr_mirror_completed_at"; then
    echo "Failed to publish the OMR mirror completion proof file."
    cleanup_uncommitted_omr_proofs || true
    return 1
  fi
  omr_completed_tmp=""
}

if [[ "${MIRROR_RELEASE_SIGNATURES:-no}" == "yes" ]]; then
  if ! mirror_release_signatures; then
    echo "Release signature mirroring failed, exiting ..."
    exit 1
  fi
fi

line_num=$(grep -n "To use the new mirrored repository for upgrades" "${mirror_output}" | awk -F: '{print $1}')
install_end_line_num=$(expr ${line_num} - 3) &&
upgrade_start_line_num=$(expr ${line_num} + 2) &&
sed -n "/^${regex_keyword_1}/,${install_end_line_num}p" "${mirror_output}" > "${install_config_mirror_patch}"
sed -n "${upgrade_start_line_num},\$p" "${mirror_output}" > "${cluster_mirror_conf_file}"

run_command "cat '${install_config_mirror_patch}'"
rm -f "${new_pull_secret}"
