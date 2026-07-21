#!/bin/bash

set -o nounset
set -o errexit
set -o pipefail

export HOME="${HOME:-/tmp/home}"
export XDG_RUNTIME_DIR="${HOME}/run"
mkdir -p "${XDG_RUNTIME_DIR}"
umask 077

# Preconfiguration steps record 100 on failure and 0 on success for the
# gather-must-gather step.
EXIT_CODE=100
work_dir=""
remote_work_dir=""
remote_runner=""
remote_cleanup_ready=false
publication_started=false
new_pull_secret=""
new_pull_secret_tmp=""
idms_tmp=""
signature_json_tmp=""
signature_yaml_tmp=""
install_patch_tmp=""
omr_repository_tmp=""
omr_cli_tmp=""
omr_completed_tmp=""
declare -a ssh_options=()

install_config_mirror_patch="${SHARED_DIR}/install-config-mirror.yaml.patch"
signature_configmap_json="${SHARED_DIR}/oc-mirror-signature-configmap.json"
signature_configmap_yaml="${SHARED_DIR}/oc-mirror-signature-configmap.yaml"
omr_repository_file="${SHARED_DIR}/omr_mirror_repository"
omr_cli_file="${SHARED_DIR}/omr_mirrored_cli_image"
omr_completed_file="${SHARED_DIR}/omr_mirror_completed_at"

function cleanup_uncommitted_outputs() {
  local cleanup_failed=false
  local -a temp_files=()

  for path in \
    "${idms_tmp}" \
    "${signature_json_tmp}" \
    "${signature_yaml_tmp}" \
    "${install_patch_tmp}" \
    "${omr_repository_tmp}" \
    "${omr_cli_tmp}" \
    "${omr_completed_tmp}"; do
    [[ -z "${path}" ]] || temp_files+=("${path}")
  done

  if (( ${#temp_files[@]} > 0 )); then
    if ! rm -f -- "${temp_files[@]}"; then
      echo "Failed to remove temporary OMR mirror outputs."
      cleanup_failed=true
    fi
  fi

  if [[ "${publication_started}" == true && ! -s "${omr_completed_file}" ]]; then
    if ! rm -f -- \
      "${install_config_mirror_patch}" \
      "${signature_configmap_json}" \
      "${signature_configmap_yaml}" \
      "${omr_repository_file}" \
      "${omr_cli_file}"; then
      echo "Failed to remove partially published OMR mirror outputs."
      cleanup_failed=true
    fi
  fi

  [[ "${cleanup_failed}" == false ]]
}

function cleanup_on_exit() {
  local original_status="$1"

  if [[ "${original_status}" == 0 ]]; then
    EXIT_CODE=0
  fi

  cleanup_uncommitted_outputs || true
  [[ -z "${new_pull_secret_tmp}" ]] || rm -f -- "${new_pull_secret_tmp}" || true
  [[ -z "${new_pull_secret}" ]] || rm -f -- "${new_pull_secret}" || true
  if [[ -n "${work_dir}" && -d "${work_dir}" ]]; then
    rm -rf -- "${work_dir}" || true
  fi

  if [[ "${remote_cleanup_ready}" == true && -n "${remote_work_dir}" ]]; then
    ssh "${ssh_options[@]}" "${BASTION_SSH_USER}@${BASTION_IP}" \
      "rm -rf -- '${remote_work_dir}'" > /dev/null 2>&1 || true
  fi

  printf '%s\n' "${EXIT_CODE}" > "${SHARED_DIR}/install-pre-config-status.txt"
}

function terminate_on_term() {
  trap - TERM
  exit 143
}

function collect_release_info() {
  local output_file="$1"
  local attempt=1
  local max_attempts=3
  local retry_delay_seconds=60

  while (( attempt <= max_attempts )); do
    echo "Collecting release image information attempt ${attempt}/${max_attempts}."
    if oc adm release info \
      -a "${new_pull_secret}" \
      --include-images \
      -o json \
      "${OPENSHIFT_INSTALL_RELEASE_IMAGE_OVERRIDE}" > "${output_file}"; then
      return 0
    fi

    echo "Collecting release image information attempt ${attempt}/${max_attempts} failed."
    if (( attempt >= max_attempts )); then
      break
    fi
    echo "Trying release image information collection again in ${retry_delay_seconds} seconds."
    if ! sleep "${retry_delay_seconds}"; then
      echo "Interrupted while waiting to retry release image information collection."
      return 1
    fi
    ((attempt += 1))
  done

  return 1
}

function download_oc_mirror() {
  local architecture
  local base_url
  local checksum_line

  case "$(uname -m)" in
    x86_64)
      architecture=amd64
      ;;
    aarch64)
      architecture=arm64
      ;;
    ppc64le|s390x)
      architecture=$(uname -m)
      ;;
    *)
      echo "Unsupported oc-mirror client architecture: $(uname -m)"
      return 1
      ;;
  esac

  base_url="https://mirror.openshift.com/pub/openshift-v4/${architecture}/clients/ocp/latest"
  curl -fL --retry 5 --connect-timeout 30 \
    -o "${work_dir}/oc-mirror.tar.gz" \
    "${base_url}/oc-mirror.tar.gz"
  curl -fL --retry 5 --connect-timeout 30 \
    -o "${work_dir}/sha256sum.txt" \
    "${base_url}/sha256sum.txt"

  checksum_line=$(grep -E '(^|[[:space:]*])oc-mirror\.tar\.gz$' \
    "${work_dir}/sha256sum.txt" | head -n 1)
  if [[ -z "${checksum_line}" ]]; then
    echo "The published checksum list does not contain oc-mirror.tar.gz."
    return 1
  fi
  (
    cd "${work_dir}"
    printf '%s\n' "${checksum_line}" | sha256sum -c -
  )

  tar -xzf "${work_dir}/oc-mirror.tar.gz" -C "${work_dir}" oc-mirror
  chmod 0755 "${work_dir}/oc-mirror"
  "${work_dir}/oc-mirror" version --output=yaml | \
    tee "${ARTIFACT_DIR}/oc-mirror-version.yaml"
}

function write_install_config_mirror_patch() {
  local idms_file="$1"
  local output_file="$2"
  local mirror_host="$3"
  local release_image="$4"
  local release_source="${release_image%@*}"
  local release_mirror="${mirror_host}/openshift/release-images"
  local release_mirrors
  local updated_patch
  local num_sources

  yq-v4 eval-all '
    .spec.imageDigestMirrors as $item
    ireduce ([]; . + $item)
    | {"imageDigestSources": .}
  ' "${idms_file}" > "${output_file}"

  if ! yq-v4 eval -o=json '.' "${output_file}" | jq -e \
    --arg source "${release_source}" \
    'any(.imageDigestSources[]?; .source == $source)' > /dev/null; then
    if ! release_mirrors=$(yq-v4 eval -o=json '.' "${output_file}" | jq -ce \
      --arg mirror "${release_mirror}" '
        first(
          .imageDigestSources[]?
          | select(any(.mirrors[]?; . == $mirror))
        ).mirrors
      '); then
      echo "The generated IDMS has no platform release mapping for ${release_mirror}."
      return 1
    fi
    if ! updated_patch=$(yq-v4 eval -o=json '.' "${output_file}" | jq -ce \
      --arg source "${release_source}" \
      --argjson mirrors "${release_mirrors}" '
        .imageDigestSources += [{"mirrors": $mirrors, "source": $source}]
      '); then
      echo "Failed to add the ci-operator release source to the installer mirror patch."
      return 1
    fi
    printf '%s\n' "${updated_patch}" | yq-v4 eval -P '.' - > "${output_file}"
  fi

  num_sources=$(yq-v4 eval '.imageDigestSources | length' "${output_file}")
  if [[ ! "${num_sources}" =~ ^[1-9][0-9]*$ ]]; then
    echo "The generated installer mirror patch has no imageDigestSources."
    return 1
  fi
}

function validate_generated_mappings() {
  local patch_file="$1"
  local mirror_host="$2"
  local release_image="$3"
  local release_source="${release_image%@*}"
  local source

  if [[ "${release_source}" == "${release_image}" ]]; then
    echo "Release image does not contain a digest: ${release_image}"
    return 1
  fi

  for source in \
    "${release_source}" \
    quay.io/openshift-release-dev/ocp-v4.0-art-dev; do
    if ! yq-v4 eval -o=json '.' "${patch_file}" | jq -e \
      --arg source "${source}" \
      --arg mirror "${mirror_host}/" '
        any(.imageDigestSources[]?;
          .source == $source and any(.mirrors[]?; startswith($mirror)))
      ' > /dev/null; then
      echo "Generated IDMS does not map ${source} to ${mirror_host}."
      return 1
    fi
  done
}

function run_remote_mirror_with_retries() {
  local attempt=1

  while (( attempt <= MAX_ATTEMPTS )); do
    echo "Mirroring images attempt ${attempt}/${MAX_ATTEMPTS}."
    if ssh "${ssh_options[@]}" "${BASTION_SSH_USER}@${BASTION_IP}" \
      "'${remote_runner}' '${remote_work_dir}' '${MIRROR_REGISTRY_HOST}'"; then
      echo "Mirroring images succeeded on attempt ${attempt}."
      return 0
    fi

    echo "Mirroring images attempt ${attempt}/${MAX_ATTEMPTS} failed."
    if (( attempt >= MAX_ATTEMPTS )); then
      break
    fi
    echo "Trying image mirroring again in 120 seconds."
    if ! sleep 120; then
      echo "Interrupted while waiting to retry image mirroring."
      return 1
    fi
    ((attempt += 1))
  done

  return 1
}

trap 'cleanup_on_exit "$?"' EXIT
trap terminate_on_term TERM

mkdir -p "${ARTIFACT_DIR}"
for command in base64 curl jq oc scp sha256sum ssh tar tee yq-v4; do
  if ! command -v "${command}" > /dev/null 2>&1; then
    echo "Required command ${command} is unavailable in the mirror step image."
    exit 1
  fi
done

remote_address_file="${SHARED_DIR}/bastion_private_address"
remote_user_file="${SHARED_DIR}/bastion_ssh_user"
if [[ -s "${SHARED_DIR}/omr_host_public_address" ||
      -s "${SHARED_DIR}/omr_host_ssh_user" ]]; then
  remote_address_file="${SHARED_DIR}/omr_host_public_address"
  remote_user_file="${SHARED_DIR}/omr_host_ssh_user"
fi

for required_file in \
  "${SHARED_DIR}/mirror_registry_url" \
  "${SHARED_DIR}/mirror_registry_creds" \
  "${SHARED_DIR}/mirror_registry_ca.crt" \
  "${remote_address_file}" \
  "${remote_user_file}" \
  "${CLUSTER_PROFILE_DIR}/pull-secret" \
  "${CLUSTER_PROFILE_DIR}/ssh-privatekey"; do
  if [[ ! -s "${required_file}" ]]; then
    echo "Required mirror input ${required_file} does not exist or is empty."
    exit 1
  fi
done

MIRROR_REGISTRY_HOST=$(head -n 1 "${SHARED_DIR}/mirror_registry_url")
if [[ ! "${MIRROR_REGISTRY_HOST}" =~ ^[A-Za-z0-9][A-Za-z0-9.-]*:[0-9]+$ ]]; then
  echo "The runtime OMR endpoint is invalid."
  exit 1
fi
echo "MIRROR_REGISTRY_HOST: ${MIRROR_REGISTRY_HOST}"
echo "OPENSHIFT_INSTALL_RELEASE_IMAGE_OVERRIDE: ${OPENSHIFT_INSTALL_RELEASE_IMAGE_OVERRIDE}"

publication_started=true
rm -f -- \
  "${install_config_mirror_patch}" \
  "${signature_configmap_json}" \
  "${signature_configmap_yaml}" \
  "${omr_repository_file}" \
  "${omr_cli_file}" \
  "${omr_completed_file}" \
  "${SHARED_DIR}/local_registry_mirror_file.yaml"

work_dir=$(mktemp -d /tmp/quay-omr-v3-mirror.XXXXXX)
chmod 0700 "${work_dir}"
new_pull_secret="${SHARED_DIR}/quay_omr_v3_pull_secret"

# Since ci-operator can inject a kubeconfig for the cluster under test, unset it
# so registry login always targets the build farm.
unset KUBECONFIG
oc registry login

cp "${CLUSTER_PROFILE_DIR}/pull-secret" "${new_pull_secret}"
chmod 0600 "${new_pull_secret}"
oc registry login --to "${new_pull_secret}"

registry_credentials=$(tr -d '\r\n' < "${SHARED_DIR}/mirror_registry_creds")
if [[ -z "${registry_credentials}" || "${registry_credentials}" != *:* ]]; then
  echo "The runtime OMR credential is invalid."
  exit 1
fi
registry_cred=$(printf '%s' "${registry_credentials}" | base64 -w 0)
unset registry_credentials

new_pull_secret_tmp=$(mktemp "${SHARED_DIR}/.quay_omr_v3_pull_secret.XXXXXX")
jq --arg host "${MIRROR_REGISTRY_HOST}" --arg auth "${registry_cred}" '
  .auths = (.auths // {}) | .auths[$host] = {"auth": $auth}
' "${new_pull_secret}" > "${new_pull_secret_tmp}"
chmod 0600 "${new_pull_secret_tmp}"
mv -f -- "${new_pull_secret_tmp}" "${new_pull_secret}"
new_pull_secret_tmp=""

release_info_file="${work_dir}/release-info.json"
if ! collect_release_info "${release_info_file}"; then
  echo "Failed to collect release image information."
  exit 1
fi
cli_digest=$(jq -er '
  first(.references.spec.tags[]? | select(.name == "cli") | .from.name)
  | capture("@(?<digest>sha256:[a-f0-9]{64})$").digest
' "${release_info_file}")

download_oc_mirror

cat > "${work_dir}/imageset-config.yaml" <<EOF
apiVersion: mirror.openshift.io/v2alpha1
kind: ImageSetConfiguration
mirror:
  platform:
    architectures:
    - amd64
    release: ${OPENSHIFT_INSTALL_RELEASE_IMAGE_OVERRIDE}
EOF
cp "${work_dir}/imageset-config.yaml" "${ARTIFACT_DIR}/imageset-config.yaml"

if ! whoami > /dev/null 2>&1; then
  if [[ -w /etc/passwd ]]; then
    echo "${USER_NAME:-default}:x:$(id -u):0:${USER_NAME:-default} user:${HOME}:/sbin/nologin" >> /etc/passwd
  else
    echo "/etc/passwd is not writable and the current UID has no passwd entry."
    exit 1
  fi
fi

BASTION_IP=$(<"${remote_address_file}")
if [[ "${remote_address_file}" == "${SHARED_DIR}/bastion_private_address" &&
      -s "${SHARED_DIR}/bastion_public_address" ]]; then
  BASTION_IP=$(<"${SHARED_DIR}/bastion_public_address")
fi
BASTION_SSH_USER=$(<"${remote_user_file}")
if [[ ! "${BASTION_IP}" =~ ^[A-Za-z0-9][A-Za-z0-9.-]*$ ]] ||
   [[ ! "${BASTION_SSH_USER}" =~ ^[A-Za-z_][A-Za-z0-9_-]*$ ]] ||
   [[ ! "${UNIQUE_HASH}" =~ ^[A-Za-z0-9]+$ ]]; then
  echo "A bastion SSH input or UNIQUE_HASH is invalid."
  exit 1
fi

ssh_options=(
  -o UserKnownHostsFile=/dev/null
  -o StrictHostKeyChecking=no
  -o "IdentityFile=${CLUSTER_PROFILE_DIR}/ssh-privatekey"
  -o ConnectTimeout=10
  -o ConnectionAttempts=3
)
remote_work_dir="/tmp/quay-omr-v3-mirror-${UNIQUE_HASH}"
remote_runner="${remote_work_dir}/run-oc-mirror"

cat > "${work_dir}/run-oc-mirror" <<'EOF'
#!/bin/bash
set -o nounset
set -o errexit
set -o pipefail
umask 0022

work_dir="$1"
mirror_host="$2"
export HOME="${work_dir}/home"
export XDG_RUNTIME_DIR="${HOME}/run"
mkdir -p \
  "${XDG_RUNTIME_DIR}/containers" \
  "${HOME}/.config/containers/certs.d/${mirror_host}"
cp "${work_dir}/auth.json" "${XDG_RUNTIME_DIR}/containers/auth.json"
cp "${work_dir}/omr-ca.crt" \
  "${HOME}/.config/containers/certs.d/${mirror_host}/ca.crt"
chmod 0600 "${XDG_RUNTIME_DIR}/containers/auth.json"

exec "${work_dir}/oc-mirror" \
  --v2 \
  --config "${work_dir}/imageset-config.yaml" \
  --workspace "file://${work_dir}/workspace" \
  --authfile "${XDG_RUNTIME_DIR}/containers/auth.json" \
  --retry-times=5 \
  --log-level=info \
  "docker://${mirror_host}"
EOF
chmod 0755 "${work_dir}/run-oc-mirror"

ssh "${ssh_options[@]}" "${BASTION_SSH_USER}@${BASTION_IP}" \
  "rm -rf -- '${remote_work_dir}' && install -d -m 0700 '${remote_work_dir}'"
remote_cleanup_ready=true
scp "${ssh_options[@]}" "${work_dir}/oc-mirror" \
  "${BASTION_SSH_USER}@${BASTION_IP}:${remote_work_dir}/oc-mirror"
scp "${ssh_options[@]}" "${work_dir}/run-oc-mirror" \
  "${BASTION_SSH_USER}@${BASTION_IP}:${remote_runner}"
scp "${ssh_options[@]}" "${work_dir}/imageset-config.yaml" \
  "${BASTION_SSH_USER}@${BASTION_IP}:${remote_work_dir}/imageset-config.yaml"
scp "${ssh_options[@]}" "${new_pull_secret}" \
  "${BASTION_SSH_USER}@${BASTION_IP}:${remote_work_dir}/auth.json"
scp "${ssh_options[@]}" "${SHARED_DIR}/mirror_registry_ca.crt" \
  "${BASTION_SSH_USER}@${BASTION_IP}:${remote_work_dir}/omr-ca.crt"
ssh "${ssh_options[@]}" "${BASTION_SSH_USER}@${BASTION_IP}" \
  "chmod 0755 '${remote_work_dir}/oc-mirror' '${remote_runner}' &&
   chmod 0600 '${remote_work_dir}/auth.json' '${remote_work_dir}/omr-ca.crt'"

MAX_ATTEMPTS=5
mirror_output="${ARTIFACT_DIR}/oc-mirror-output.log"
if ! run_remote_mirror_with_retries 2>&1 | tee "${mirror_output}"; then
  echo "Mirroring images failed after ${MAX_ATTEMPTS} attempts."
  exit 1
fi

idms_tmp=$(mktemp "${SHARED_DIR}/.idms-oc-mirror.yaml.XXXXXX")
signature_json_tmp=$(mktemp "${SHARED_DIR}/.signature-configmap.json.XXXXXX")
signature_yaml_tmp=$(mktemp "${SHARED_DIR}/.signature-configmap.yaml.XXXXXX")
install_patch_tmp=$(mktemp "${SHARED_DIR}/.install-config-mirror.yaml.patch.XXXXXX")

remote_cluster_resources="${remote_work_dir}/workspace/working-dir/cluster-resources"
scp "${ssh_options[@]}" \
  "${BASTION_SSH_USER}@${BASTION_IP}:${remote_cluster_resources}/idms-oc-mirror.yaml" \
  "${idms_tmp}"
scp "${ssh_options[@]}" \
  "${BASTION_SSH_USER}@${BASTION_IP}:${remote_cluster_resources}/signature-configmap.json" \
  "${signature_json_tmp}"
scp "${ssh_options[@]}" \
  "${BASTION_SSH_USER}@${BASTION_IP}:${remote_cluster_resources}/signature-configmap.yaml" \
  "${signature_yaml_tmp}"

for generated_file in "${idms_tmp}" "${signature_json_tmp}" "${signature_yaml_tmp}"; do
  if [[ ! -s "${generated_file}" ]]; then
    echo "Required oc-mirror output ${generated_file} is missing or empty."
    exit 1
  fi
done

if ! jq -e '
  .apiVersion == "v1"
  and .kind == "ConfigMap"
  and .metadata.name == "mirrored-release-signatures"
  and .metadata.namespace == "openshift-config-managed"
  and (.binaryData | type == "object" and length > 0)
' "${signature_json_tmp}" > /dev/null; then
  echo "The generated oc-mirror release signature ConfigMap is invalid."
  exit 1
fi

write_install_config_mirror_patch \
  "${idms_tmp}" \
  "${install_patch_tmp}" \
  "${MIRROR_REGISTRY_HOST}" \
  "${OPENSHIFT_INSTALL_RELEASE_IMAGE_OVERRIDE}"
validate_generated_mappings \
  "${install_patch_tmp}" \
  "${MIRROR_REGISTRY_HOST}" \
  "${OPENSHIFT_INSTALL_RELEASE_IMAGE_OVERRIDE}"

component_mirror=$(yq-v4 eval -o=json '.' "${install_patch_tmp}" | jq -er \
  --arg source quay.io/openshift-release-dev/ocp-v4.0-art-dev \
  --arg prefix "${MIRROR_REGISTRY_HOST}/" '
    first(
      .imageDigestSources[]?
      | select(.source == $source)
      | .mirrors[]?
      | select(startswith($prefix))
    )
  ')

cp "${install_patch_tmp}" "${ARTIFACT_DIR}/install-config-mirror.yaml.patch"
artifact_tmp="${ARTIFACT_DIR}/.oc-mirror-generated-output.tar.gz"
if ssh "${ssh_options[@]}" "${BASTION_SSH_USER}@${BASTION_IP}" \
  "tar -C '${remote_work_dir}/workspace/working-dir' -czf - logs cluster-resources" \
  > "${artifact_tmp}"; then
  mv -f -- "${artifact_tmp}" "${ARTIFACT_DIR}/oc-mirror-generated-output.tar.gz"
else
  echo "Failed to capture optional oc-mirror generated-output archive."
  rm -f -- "${artifact_tmp}"
fi

omr_repository_tmp=$(mktemp "${SHARED_DIR}/.omr_mirror_repository.XXXXXX")
omr_cli_tmp=$(mktemp "${SHARED_DIR}/.omr_mirrored_cli_image.XXXXXX")
omr_completed_tmp=$(mktemp "${SHARED_DIR}/.omr_mirror_completed_at.XXXXXX")
printf '%s\n' "${component_mirror}" > "${omr_repository_tmp}"
printf '%s@%s\n' "${component_mirror}" "${cli_digest}" > "${omr_cli_tmp}"
date -u +%Y-%m-%dT%H:%M:%SZ > "${omr_completed_tmp}"
chmod 0644 \
  "${install_patch_tmp}" \
  "${signature_json_tmp}" \
  "${signature_yaml_tmp}" \
  "${omr_repository_tmp}" \
  "${omr_cli_tmp}" \
  "${omr_completed_tmp}"

mv -f -- "${install_patch_tmp}" "${install_config_mirror_patch}"
install_patch_tmp=""
mv -f -- "${signature_json_tmp}" "${signature_configmap_json}"
signature_json_tmp=""
mv -f -- "${signature_yaml_tmp}" "${signature_configmap_yaml}"
signature_yaml_tmp=""
mv -f -- "${omr_repository_tmp}" "${omr_repository_file}"
omr_repository_tmp=""
mv -f -- "${omr_cli_tmp}" "${omr_cli_file}"
omr_cli_tmp=""
# Publish the completion timestamp last so cleanup can detect partial output.
mv -f -- "${omr_completed_tmp}" "${omr_completed_file}"
omr_completed_tmp=""

echo "oc-mirror v2 populated OMR and published disconnected install resources."
