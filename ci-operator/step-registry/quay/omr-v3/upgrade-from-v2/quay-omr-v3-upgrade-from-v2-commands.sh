#!/bin/bash

set -o nounset
set -o errexit
set -o pipefail

umask 077
work_dir=""
remote_work_dir=""
remote_ready=false
declare -a ssh_options=()

cleanup() {
    local status=$?

    trap - EXIT TERM
    set +o errexit
    if [[ "${remote_ready}" == true ]]; then
        ssh "${ssh_options[@]}" "${host_user}@${host_address}" \
            "rm -rf -- '${remote_work_dir}'" >/dev/null 2>&1 || true
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
: "${OMR_IMAGE:?OMR_IMAGE must identify the PR-built quay-mirror image}"

for command in oc scp sha256sum skopeo ssh; do
    if ! command -v "${command}" >/dev/null 2>&1; then
        echo "Required command ${command} is unavailable in the migration step image." >&2
        exit 1
    fi
done

for required_file in \
    "${CLUSTER_PROFILE_DIR}/ssh-privatekey" \
    "${SHARED_DIR}/mirror_registry_ca.crt" \
    "${SHARED_DIR}/mirror_registry_creds" \
    "${SHARED_DIR}/mirror_registry_url" \
    "${SHARED_DIR}/omr_host_public_address" \
    "${SHARED_DIR}/omr_host_ssh_user"; do
    if [[ ! -s "${required_file}" ]]; then
        echo "Required OMR migration input ${required_file} is missing or empty." >&2
        exit 1
    fi
done

host_address=$(<"${SHARED_DIR}/omr_host_public_address")
host_user=$(<"${SHARED_DIR}/omr_host_ssh_user")
if [[ ! "${host_address}" =~ ^[A-Za-z0-9][A-Za-z0-9.-]*$ ]] ||
   [[ ! "${host_user}" =~ ^[A-Za-z_][A-Za-z0-9_-]*$ ]] ||
   [[ ! "${UNIQUE_HASH}" =~ ^[A-Za-z0-9]+$ ]]; then
    echo "A dedicated OMR host connection value or UNIQUE_HASH is invalid." >&2
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

work_dir=$(mktemp -d /tmp/quay-omr-v3-migrate.XXXXXX)
chmod 0700 "${work_dir}"
auth_file="${work_dir}/registry-auth.json"
image_archive="${work_dir}/quay-mirror.tar"
extract_dir="${work_dir}/extract"
mkdir -p "${extract_dir}"

unset KUBECONFIG
oc registry login --to="${auth_file}"
chmod 0600 "${auth_file}"
skopeo copy --retry-times=3 --src-authfile="${auth_file}" \
    "docker://${OMR_IMAGE}" \
    "docker-archive:${image_archive}:quay-mirror:ci"
[[ -s "${image_archive}" ]]
oc image extract "${OMR_IMAGE}" \
    --registry-config="${auth_file}" \
    --path="/quay:${extract_dir}"
if [[ ! -s "${extract_dir}/quay" ]]; then
    echo "The extracted OMR v3 installer binary is missing or empty." >&2
    exit 1
fi
chmod 0755 "${extract_dir}/quay"

sha256sum \
    "${SHARED_DIR}/mirror_registry_ca.crt" \
    "${SHARED_DIR}/mirror_registry_creds" \
    "${SHARED_DIR}/mirror_registry_url" \
    > "${work_dir}/runtime-material.sha256"

ssh_options=(
    -o UserKnownHostsFile=/dev/null
    -o StrictHostKeyChecking=no
    -o "IdentityFile=${CLUSTER_PROFILE_DIR}/ssh-privatekey"
    -o ConnectTimeout=10
    -o ConnectionAttempts=3
)
remote="${host_user}@${host_address}"
remote_work_dir="/home/${host_user}/omr-v3-upgrade-${UNIQUE_HASH}"
ssh "${ssh_options[@]}" "${remote}" \
    "rm -rf -- '${remote_work_dir}' && install -d -m 0700 '${remote_work_dir}'"
remote_ready=true

cat > "${work_dir}/migrate-to-v3" <<'EOF'
#!/bin/bash
set -o nounset
set -o errexit
set -o pipefail
umask 077

work_dir="$1"
data_dir="/home/$(id -un)/quay-v3"
registry_hostname="$2"
registry_endpoint="${registry_hostname}:8443"
export XDG_RUNTIME_DIR="/run/user/$(id -u)"

if ! "${work_dir}/quay" migrate \
    -data-dir "${data_dir}" \
    -image-archive "${work_dir}/quay-mirror.tar" \
    -cleanup > "${work_dir}/migration.log" 2>&1; then
    echo "OMR v3 migration failed; see the sanitized migration artifact." >&2
    exit 1
fi

systemctl --user is-active --quiet quay.service
for service in quay-app.service quay-redis.service quay-pod.service; do
    if systemctl --user is-active --quiet "${service}"; then
        echo "Old OMR v2 service ${service} is still active." >&2
        exit 1
    fi
    if [[ -e "/home/$(id -un)/.config/systemd/user/${service}" ]]; then
        echo "Old OMR v2 unit ${service} was not removed." >&2
        exit 1
    fi
done

curl --retry 20 --retry-delay 3 --retry-all-errors \
    --silent --show-error --fail \
    --cacert "/home/$(id -un)/quay-install/quay-rootCA/rootCA.pem" \
    "https://${registry_endpoint}/healthz" >/dev/null
cert_dir="${work_dir}/certs"
auth_file="${work_dir}/registry-auth.json"
install -d -m 0700 "${cert_dir}"
install -m 0600 \
    "/home/$(id -un)/quay-install/quay-rootCA/rootCA.pem" \
    "${cert_dir}/ca.crt"
admin_password=$(<"/home/$(id -un)/.omr-v2-admin-password")
if ! printf '%s' "${admin_password}" | podman login \
    --authfile "${auth_file}" \
    --cert-dir "${cert_dir}" \
    --tls-verify=true \
    --username admin \
    --password-stdin \
    "${registry_endpoint}" >/dev/null; then
    unset admin_password
    echo "The migrated OMR v3 registry rejected the preserved administrator credential." >&2
    exit 1
fi
unset admin_password
EOF
chmod 0755 "${work_dir}/migrate-to-v3"

scp "${ssh_options[@]}" "${image_archive}" \
    "${remote}:${remote_work_dir}/quay-mirror.tar"
scp "${ssh_options[@]}" "${extract_dir}/quay" \
    "${remote}:${remote_work_dir}/quay"
scp "${ssh_options[@]}" "${work_dir}/migrate-to-v3" \
    "${remote}:${remote_work_dir}/migrate-to-v3"
ssh "${ssh_options[@]}" "${remote}" \
    "chmod 0755 '${remote_work_dir}/quay' '${remote_work_dir}/migrate-to-v3'"

registry_endpoint=$(<"${SHARED_DIR}/mirror_registry_url")
registry_hostname="${registry_endpoint%:8443}"
if [[ ! "${registry_hostname}" =~ ^[A-Za-z0-9][A-Za-z0-9.-]*$ ]]; then
    echo "The runtime OMR hostname is invalid." >&2
    exit 1
fi

migration_status=0
ssh "${ssh_options[@]}" "${remote}" \
    "'${remote_work_dir}/migrate-to-v3' '${remote_work_dir}' '${registry_hostname}'" || migration_status=$?
scp "${ssh_options[@]}" "${remote}:${remote_work_dir}/migration.log" \
    "${ARTIFACT_DIR}/omr-v3-migration.log" 2>/dev/null || true
if [[ "${migration_status}" -ne 0 ]]; then
    echo "OMR v3 migration failed with status ${migration_status}."
    exit "${migration_status}"
fi

sha256sum --check "${work_dir}/runtime-material.sha256"
echo "OMR v2 content and runtime identity migrated successfully to rootless OMR v3."
