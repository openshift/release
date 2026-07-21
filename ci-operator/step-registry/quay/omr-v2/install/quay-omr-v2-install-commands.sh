#!/bin/bash

set -o nounset
set -o errexit
set -o pipefail

umask 077
EXIT_CODE=100
work_dir=""
published=false
declare -a ssh_options=()
declare -a runtime_files=(
    "${SHARED_DIR}/mirror_registry_url"
    "${SHARED_DIR}/mirror_registry_creds"
    "${SHARED_DIR}/mirror_registry_ca.crt"
    "${SHARED_DIR}/omr_v2_version"
    "${SHARED_DIR}/omr_v2_sha256"
)

cleanup() {
    local status=$?

    trap - EXIT TERM
    set +o errexit
    if [[ "${status}" -eq 0 ]]; then
        EXIT_CODE=0
    fi
    printf '%s\n' "${EXIT_CODE}" > "${SHARED_DIR}/install-pre-config-status.txt"
    if [[ "${published}" != true ]]; then
        rm -f -- "${runtime_files[@]}"
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
rm -f -- "${runtime_files[@]}"

for command in scp ssh; do
    if ! command -v "${command}" >/dev/null 2>&1; then
        echo "Required command ${command} is unavailable in the OMR v2 install step image." >&2
        exit 1
    fi
done

for required_file in \
    "${CLUSTER_PROFILE_DIR}/ssh-privatekey" \
    "${SHARED_DIR}/omr_host_private_address" \
    "${SHARED_DIR}/omr_host_public_address" \
    "${SHARED_DIR}/omr_host_ssh_user"; do
    if [[ ! -s "${required_file}" ]]; then
        echo "Required OMR v2 install input ${required_file} is missing or empty." >&2
        exit 1
    fi
done

safe_download_url_re='^https://[A-Za-z0-9./_?&=%:+-]+$'
if [[ ! "${OMR_V2_DOWNLOAD_URL}" =~ ${safe_download_url_re} ]]; then
    echo "OMR_V2_DOWNLOAD_URL must be a safely quoted HTTPS URL." >&2
    exit 1
fi

host_public=$(<"${SHARED_DIR}/omr_host_public_address")
host_private=$(<"${SHARED_DIR}/omr_host_private_address")
host_user=$(<"${SHARED_DIR}/omr_host_ssh_user")
if [[ ! "${host_public}" =~ ^[A-Za-z0-9][A-Za-z0-9.-]*$ ]] ||
   [[ ! "${host_private}" =~ ^[A-Za-z0-9][A-Za-z0-9.-]*$ ]] ||
   [[ ! "${host_user}" =~ ^[A-Za-z_][A-Za-z0-9_-]*$ ]]; then
    echo "A dedicated OMR host connection value is invalid." >&2
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

ssh_options=(
    -o UserKnownHostsFile=/dev/null
    -o StrictHostKeyChecking=no
    -o "IdentityFile=${CLUSTER_PROFILE_DIR}/ssh-privatekey"
    -o ConnectTimeout=10
    -o ConnectionAttempts=3
)
remote="${host_user}@${host_public}"
remote_work_dir="/home/${host_user}/omr-v2-artifact"
work_dir=$(mktemp -d /tmp/quay-omr-v2-install.XXXXXX)
chmod 0700 "${work_dir}"

cat > "${work_dir}/install-omr-v2" <<'EOF'
#!/bin/bash
set -o nounset
set -o errexit
set -o pipefail
umask 077

download_url="$1"
registry_hostname="$2"
work_dir="$3"
quay_root="/home/$(id -un)/quay-install"
quay_storage="${quay_root}/quay-storage"
sqlite_storage="${quay_root}/sqlite-storage"
archive="${work_dir}/mirror-registry-amd64.tar.gz"

rm -rf -- "${work_dir}"
install -d -m 0700 "${work_dir}"
curl --fail --location --retry 5 --connect-timeout 30 \
    --output "${archive}" "${download_url}"
sha256sum "${archive}" | awk '{print $1}' > "${work_dir}/sha256"
tar -xzf "${archive}" -C "${work_dir}"
if [[ ! -x "${work_dir}/mirror-registry" ]]; then
    echo "The extracted mirror-registry executable is missing." >&2
    exit 1
fi

version_output=$("${work_dir}/mirror-registry" --version 2>&1)
printf '%s\n' "${version_output}" > "${work_dir}/version-output"
version=$(printf '%s\n' "${version_output}" | grep -Eo 'v?2\.[0-9]+\.[0-9]+' | \
    head -n 1 | sed 's/^v//' || true)
if [[ -z "${version}" || "${version%%.*}" != 2 ]]; then
    echo "The floating mirror-registry artifact is not an identifiable v2 release." >&2
    exit 1
fi
printf '%s\n' "${version}" > "${work_dir}/version"

install -d -m 0700 "${quay_root}" "${quay_storage}" "${sqlite_storage}"
openssl rand -hex 24 > "/home/$(id -un)/.omr-v2-admin-password"
chmod 0600 "/home/$(id -un)/.omr-v2-admin-password"
admin_password=$(<"/home/$(id -un)/.omr-v2-admin-password")
install_status=0
"${work_dir}/mirror-registry" install \
    --autoApprove \
    --initUser admin \
    --initPassword "${admin_password}" \
    --no-color \
    --quayHostname "${registry_hostname}" \
    --quayRoot "${quay_root}" \
    --quayStorage "${quay_storage}" \
    --sqliteStorage "${sqlite_storage}" \
    -v > "${work_dir}/install.log" 2>&1 || install_status=$?
sed "s/${admin_password}/<redacted>/g" "${work_dir}/install.log" \
    > "${work_dir}/install-sanitized.log"
chmod 0600 "${work_dir}/install-sanitized.log"
unset admin_password
if [[ "${install_status}" -ne 0 ]]; then
    echo "OMR v2 installation failed; the credential-bearing installer log remains on the host." >&2
    exit 1
fi

export XDG_RUNTIME_DIR="/run/user/$(id -u)"
for service in quay-app.service quay-redis.service quay-pod.service; do
    systemctl --user is-active --quiet "${service}"
done
curl --retry 20 --retry-delay 3 --retry-all-errors \
    --silent --show-error --fail \
    --cacert "${quay_root}/quay-rootCA/rootCA.pem" \
    "https://${registry_hostname}:8443/healthz" >/dev/null
rm -f -- "${archive}"
EOF
chmod 0755 "${work_dir}/install-omr-v2"

scp "${ssh_options[@]}" "${work_dir}/install-omr-v2" \
    "${remote}:/home/${host_user}/install-omr-v2"
install_status=0
ssh "${ssh_options[@]}" "${remote}" \
    "chmod 0755 '/home/${host_user}/install-omr-v2' &&
     '/home/${host_user}/install-omr-v2' '${OMR_V2_DOWNLOAD_URL}' '${host_private}' '${remote_work_dir}'" || install_status=$?
scp "${ssh_options[@]}" "${remote}:${remote_work_dir}/install-sanitized.log" \
    "${ARTIFACT_DIR}/mirror-registry-install.log" 2>/dev/null || true
scp "${ssh_options[@]}" "${remote}:${remote_work_dir}/version-output" \
    "${ARTIFACT_DIR}/mirror-registry-version.txt" 2>/dev/null || true
scp "${ssh_options[@]}" "${remote}:${remote_work_dir}/sha256" \
    "${ARTIFACT_DIR}/mirror-registry-sha256.txt" 2>/dev/null || true
if [[ "${install_status}" -ne 0 ]]; then
    echo "OMR v2 installation failed with status ${install_status}; available redacted diagnostics were copied to artifacts." >&2
    exit "${install_status}"
fi

scp "${ssh_options[@]}" "${remote}:${remote_work_dir}/version" "${work_dir}/version"
scp "${ssh_options[@]}" "${remote}:${remote_work_dir}/sha256" "${work_dir}/sha256"
scp "${ssh_options[@]}" \
    "${remote}:/home/${host_user}/quay-install/quay-rootCA/rootCA.pem" \
    "${work_dir}/rootCA.pem"
scp "${ssh_options[@]}" "${remote}:/home/${host_user}/.omr-v2-admin-password" \
    "${work_dir}/admin-password"

version=$(tr -d '\r\n' < "${work_dir}/version")
archive_sha=$(tr -d '\r\n' < "${work_dir}/sha256")
admin_password=$(tr -d '\r\n' < "${work_dir}/admin-password")
if [[ ! "${version}" =~ ^2\.[0-9]+\.[0-9]+$ ]] ||
   [[ ! "${archive_sha}" =~ ^[a-f0-9]{64}$ ]] ||
   [[ -z "${admin_password}" ]]; then
    echo "OMR v2 runtime metadata failed validation." >&2
    exit 1
fi
if ! grep -q '^-----BEGIN CERTIFICATE-----$' "${work_dir}/rootCA.pem" ||
   ! grep -q '^-----END CERTIFICATE-----$' "${work_dir}/rootCA.pem"; then
    echo "The OMR v2 root CA is invalid." >&2
    exit 1
fi

ca_tmp=$(mktemp "${SHARED_DIR}/.mirror_registry_ca.crt.XXXXXX")
creds_tmp=$(mktemp "${SHARED_DIR}/.mirror_registry_creds.XXXXXX")
endpoint_tmp=$(mktemp "${SHARED_DIR}/.mirror_registry_url.XXXXXX")
version_tmp=$(mktemp "${SHARED_DIR}/.omr_v2_version.XXXXXX")
sha_tmp=$(mktemp "${SHARED_DIR}/.omr_v2_sha256.XXXXXX")
cp "${work_dir}/rootCA.pem" "${ca_tmp}"
printf 'admin:%s\n' "${admin_password}" > "${creds_tmp}"
printf '%s:8443\n' "${host_private}" > "${endpoint_tmp}"
printf '%s\n' "${version}" > "${version_tmp}"
printf '%s\n' "${archive_sha}" > "${sha_tmp}"
unset admin_password
chmod 0644 "${ca_tmp}" "${endpoint_tmp}" "${version_tmp}" "${sha_tmp}"
chmod 0600 "${creds_tmp}"

mv -f -- "${ca_tmp}" "${SHARED_DIR}/mirror_registry_ca.crt"
mv -f -- "${creds_tmp}" "${SHARED_DIR}/mirror_registry_creds"
mv -f -- "${version_tmp}" "${SHARED_DIR}/omr_v2_version"
mv -f -- "${sha_tmp}" "${SHARED_DIR}/omr_v2_sha256"
# Publish the endpoint last; downstream steps treat it as the ready marker.
mv -f -- "${endpoint_tmp}" "${SHARED_DIR}/mirror_registry_url"
published=true

ssh "${ssh_options[@]}" "${remote}" "rm -f -- '/home/${host_user}/install-omr-v2'"
echo "OMR v${version} is healthy on the dedicated RHEL host (archive SHA-256 ${archive_sha})."
