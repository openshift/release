#!/bin/bash

set -o nounset
set -o errexit
set -o pipefail

umask 077
work_dir=""
shared_tmp_dir=""

cleanup() {
    local status=$?

    trap - EXIT TERM
    set +o errexit
    if [[ -n "${shared_tmp_dir}" && -d "${shared_tmp_dir}" ]]; then
        rm -rf -- "${shared_tmp_dir}"
    fi
    if [[ -n "${work_dir}" && -d "${work_dir}" ]]; then
        rm -rf -- "${work_dir}"
    fi
    exit "${status}"
}

terminate() {
    exit 143
}

trap cleanup EXIT
trap terminate TERM

mkdir -p "${ARTIFACT_DIR}"
exec > >(tee "${ARTIFACT_DIR}/omr-v2-migration-sentinel.log") 2>&1

if [[ -f "${SHARED_DIR}/proxy-conf.sh" ]]; then
    # shellcheck disable=SC1091
    source "${SHARED_DIR}/proxy-conf.sh"
fi

for command in base64 jq oc tar; do
    if ! command -v "${command}" >/dev/null 2>&1; then
        echo "Required command ${command} is unavailable in the sentinel seed image." >&2
        exit 1
    fi
done

for required_file in \
    "${SHARED_DIR}/mirror_registry_ca.crt" \
    "${SHARED_DIR}/mirror_registry_creds" \
    "${SHARED_DIR}/mirror_registry_url" \
    "${SHARED_DIR}/omr_mirrored_cli_image"; do
    if [[ ! -s "${required_file}" ]]; then
        echo "Required sentinel seed input ${required_file} is missing or empty." >&2
        exit 1
    fi
done

: "${UNIQUE_HASH:?UNIQUE_HASH is required}"
if [[ ! "${UNIQUE_HASH}" =~ ^[A-Za-z0-9]+$ ]]; then
    echo "UNIQUE_HASH contains unexpected characters." >&2
    exit 1
fi

if ! whoami >/dev/null 2>&1; then
    if [[ -w /etc/passwd ]]; then
        echo "${USER_NAME:-default}:x:$(id -u):0:${USER_NAME:-default} user:${HOME}:/sbin/nologin" >> /etc/passwd
    else
        echo "/etc/passwd is not writable and the current UID has no passwd entry." >&2
        exit 1
    fi
fi

registry_host=$(tr -d '\r\n' < "${SHARED_DIR}/mirror_registry_url")
base_image=$(tr -d '\r\n' < "${SHARED_DIR}/omr_mirrored_cli_image")
if [[ -z "${registry_host}" || "${registry_host}" == */* ||
      "${registry_host}" =~ [[:space:]] ]]; then
    echo "The runtime OMR endpoint is invalid." >&2
    exit 1
fi
if [[ "${base_image}" != "${registry_host}/"* ||
      ! "${base_image}" =~ @sha256:[a-f0-9]{64}$ ]]; then
    echo "The mirrored CLI image is not an OMR digest pullspec: ${base_image}" >&2
    exit 1
fi

work_dir=$(mktemp -d /tmp/quay-omr-v2-sentinel.XXXXXX)
chmod 0700 "${work_dir}"
auth_file="${work_dir}/registry-auth.json"

registry_credentials=$(tr -d '\r\n' < "${SHARED_DIR}/mirror_registry_creds")
if [[ -z "${registry_credentials}" || "${registry_credentials}" != *:* ]]; then
    echo "The runtime OMR credential is invalid." >&2
    exit 1
fi
registry_auth=$(printf '%s' "${registry_credentials}" | base64 -w 0)
unset registry_credentials
jq -n --arg host "${registry_host}" --arg auth "${registry_auth}" '
  {auths: {($host): {auth: $auth}}}
' > "${auth_file}"
unset registry_auth
chmod 0600 "${auth_file}"

sentinel_repository="${registry_host}/admin/omr-migration-sentinel"
sentinel_tag="${sentinel_repository}:pre-${UNIQUE_HASH}"
sentinel_marker="omr-v2-${UNIQUE_HASH}"
rootfs="${work_dir}/rootfs"
layer_archive="${work_dir}/sentinel-layer.tar.gz"
install -d -m 0755 "${rootfs}/omr-sentinel"
printf '%s\n' "${sentinel_marker}" > "${rootfs}/omr-sentinel/pre-migration-marker"
chmod 0644 "${rootfs}/omr-sentinel/pre-migration-marker"
tar --create --gzip --file "${layer_archive}" --directory "${rootfs}" .

oc image append \
    --from="${base_image}" \
    --to="${sentinel_tag}" \
    --registry-config="${auth_file}" \
    --certificate-authority="${SHARED_DIR}/mirror_registry_ca.crt" \
    "${layer_archive}"

sentinel_info="${ARTIFACT_DIR}/omr-v2-migration-sentinel-image.json"
oc image info "${sentinel_tag}" \
    --registry-config="${auth_file}" \
    --certificate-authority="${SHARED_DIR}/mirror_registry_ca.crt" \
    -o json > "${sentinel_info}"
sentinel_digest=$(jq -er '
  .digest | select(test("^sha256:[a-f0-9]{64}$"))
' "${sentinel_info}")
sentinel_image="${sentinel_repository}@${sentinel_digest}"

rm -f -- \
    "${SHARED_DIR}/omr_migration_sentinel_digest" \
    "${SHARED_DIR}/omr_migration_sentinel_image" \
    "${SHARED_DIR}/omr_migration_sentinel_marker" \
    "${SHARED_DIR}/omr_migration_sentinel_tag"
shared_tmp_dir=$(mktemp -d "${SHARED_DIR}/.omr-migration-sentinel.XXXXXX")
printf '%s\n' "${sentinel_digest}" > "${shared_tmp_dir}/digest"
printf '%s\n' "${sentinel_image}" > "${shared_tmp_dir}/image"
printf '%s\n' "${sentinel_marker}" > "${shared_tmp_dir}/marker"
printf '%s\n' "${sentinel_tag}" > "${shared_tmp_dir}/tag"
chmod 0644 "${shared_tmp_dir}/digest" "${shared_tmp_dir}/image" \
    "${shared_tmp_dir}/marker" "${shared_tmp_dir}/tag"
mv -f -- "${shared_tmp_dir}/digest" "${SHARED_DIR}/omr_migration_sentinel_digest"
mv -f -- "${shared_tmp_dir}/marker" "${SHARED_DIR}/omr_migration_sentinel_marker"
mv -f -- "${shared_tmp_dir}/tag" "${SHARED_DIR}/omr_migration_sentinel_tag"
# Publish the immutable pullspec last so the post-migration step cannot consume
# partial sentinel metadata.
mv -f -- "${shared_tmp_dir}/image" "${SHARED_DIR}/omr_migration_sentinel_image"
rmdir "${shared_tmp_dir}"
shared_tmp_dir=""

echo "Seeded OMR v2 migration sentinel ${sentinel_image}."
