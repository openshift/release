#!/bin/bash

set -o nounset
set -o errexit
set -o pipefail

export HOME="${HOME:-/tmp/home}"
umask 077

# Preconfiguration steps record 100 on failure and 0 on success for the
# gather-must-gather step.
EXIT_CODE=100
work_dir=""
bastion_public_dns=""
bastion_private_dns=""
bastion_user=""
remote_cleanup_ready=false
published=false
ca_output_tmp=""
creds_output_tmp=""
endpoint_output_tmp=""
declare -a ssh_options=()

endpoint_file="${SHARED_DIR}/mirror_registry_url"
creds_file="${SHARED_DIR}/mirror_registry_creds"
ca_file="${SHARED_DIR}/mirror_registry_ca.crt"

cleanup() {
    local status=$?

    trap - EXIT TERM
    set +o errexit

    if [[ "${status}" -eq 0 ]]; then
        EXIT_CODE=0
    fi
    printf '%s\n' "${EXIT_CODE}" > "${SHARED_DIR}/install-pre-config-status.txt"

    if [[ "${published}" != true ]]; then
        rm -f -- "${endpoint_file}" "${creds_file}" "${ca_file}"
    fi
    [[ -z "${ca_output_tmp}" ]] || rm -f -- "${ca_output_tmp}"
    [[ -z "${creds_output_tmp}" ]] || rm -f -- "${creds_output_tmp}"
    [[ -z "${endpoint_output_tmp}" ]] || rm -f -- "${endpoint_output_tmp}"
    if [[ -n "${work_dir}" && -d "${work_dir}" ]]; then
        rm -rf -- "${work_dir}"
    fi

    if [[ "${remote_cleanup_ready}" == true ]]; then
        ssh "${ssh_options[@]}" "${bastion_user}@${bastion_public_dns}" \
            "rm -f -- '/home/${bastion_user}/quay' '/home/${bastion_user}/quay-mirror.tar'" \
            >/dev/null 2>&1 || true
    fi

    exit "${status}"
}

terminate() {
    exit 143
}

trap cleanup EXIT
trap terminate TERM

# A failed rerun must not leave runtime material from an earlier attempt.
rm -f -- "${endpoint_file}" "${creds_file}" "${ca_file}"

: "${OMR_IMAGE:?OMR_IMAGE must identify the PR-built quay-mirror image}"

for required_command in aws jq oc scp skopeo ssh; do
    if ! command -v "${required_command}" >/dev/null 2>&1; then
        echo "Required command ${required_command} is unavailable in the install step image." >&2
        exit 1
    fi
done

work_dir="$(mktemp -d /tmp/quay-omr-v3-install.XXXXXX)"
chmod 0700 "${work_dir}"
auth_file="${work_dir}/registry-auth.json"
image_archive="${work_dir}/quay-mirror.tar"
extract_dir="${work_dir}/extract"
admin_password_file="${work_dir}/admin-password"
normalized_password_file="${work_dir}/admin-password.normalized"
mkdir -p "${extract_dir}"
chmod 0700 "${extract_dir}"
: > "${admin_password_file}"
chmod 0600 "${admin_password_file}"

# Log in to the CI build registry without using an in-cluster kubeconfig.
unset KUBECONFIG
oc registry login --to="${auth_file}"
chmod 0600 "${auth_file}"

# Export the image and installer without starting a nested container runtime.
skopeo copy --retry-times=3 --src-authfile="${auth_file}" \
    "docker://${OMR_IMAGE}" \
    "docker-archive:${image_archive}:quay-mirror:ci"
[[ -s "${image_archive}" ]]

oc image extract "${OMR_IMAGE}" \
    --registry-config="${auth_file}" \
    --path="/quay:${extract_dir}"
if [[ ! -s "${extract_dir}/quay" ]]; then
    echo "The extracted OMR installer binary is missing or empty." >&2
    exit 1
fi
chmod 0755 "${extract_dir}/quay"

# OMR shares the standard bastion security group. Open its private listener
# only to the disconnected VPC before publishing the downstream ready marker.
aws_credentials="${CLUSTER_PROFILE_DIR}/.awscred"
vpc_id_file="${SHARED_DIR}/vpc_id"
if [[ ! -s "${aws_credentials}" ]] || [[ ! -s "${vpc_id_file}" ]]; then
    echo "The AWS credentials or disconnected VPC ID are missing." >&2
    exit 1
fi
export AWS_SHARED_CREDENTIALS_FILE="${aws_credentials}"
region="${REGION:-$LEASED_RESOURCE}"
stack_name="${NAMESPACE}-${UNIQUE_HASH}-bas"
vpc_id=$(<"${vpc_id_file}")

security_group_id=$(aws --region "${region}" cloudformation describe-stacks \
    --stack-name "${stack_name}" \
    --query 'Stacks[0].Outputs[?OutputKey == `BastionSecurityGroupId`].OutputValue | [0]' \
    --output text)
vpc_cidr=$(aws --region "${region}" ec2 describe-vpcs \
    --vpc-ids "${vpc_id}" \
    --query 'Vpcs[0].CidrBlock' \
    --output text)

if [[ ! "${security_group_id}" =~ ^sg-[a-f0-9]+$ ]] ||
   [[ -z "${vpc_cidr}" ]] || [[ "${vpc_cidr}" == "None" ]]; then
    echo "Could not resolve the bastion security group or disconnected VPC CIDR." >&2
    exit 1
fi

security_group_json=$(aws --region "${region}" ec2 describe-security-groups \
    --group-ids "${security_group_id}" --output json)
if jq -e --arg cidr "${vpc_cidr}" '
    .SecurityGroups[0].IpPermissions
    | any(
        .IpProtocol == "tcp"
        and .FromPort == 8443
        and .ToPort == 8443
        and any(.IpRanges[]?; .CidrIp == $cidr)
      )
  ' <<<"${security_group_json}" >/dev/null; then
    echo "The bastion security group already allows private OMR traffic."
else
    ingress_error=""
    if ! ingress_error=$(aws --region "${region}" ec2 authorize-security-group-ingress \
        --group-id "${security_group_id}" \
        --protocol tcp \
        --port 8443 \
        --cidr "${vpc_cidr}" 2>&1); then
        if [[ "${ingress_error}" == *InvalidPermission.Duplicate* ]]; then
            echo "The private OMR ingress rule was added concurrently."
        else
            echo "Failed to authorize private OMR traffic on the bastion security group." >&2
            printf '%s\n' "${ingress_error}" >&2
            exit 1
        fi
    else
        echo "Authorized private OMR traffic from the disconnected VPC."
    fi
fi

for required_file in bastion_public_address bastion_private_address bastion_ssh_user; do
    if [[ ! -s "${SHARED_DIR}/${required_file}" ]]; then
        echo "Required bastion input ${required_file} is missing or empty" >&2
        exit 1
    fi
done

bastion_public_dns="$(<"${SHARED_DIR}/bastion_public_address")"
bastion_private_dns="$(<"${SHARED_DIR}/bastion_private_address")"
bastion_user="$(<"${SHARED_DIR}/bastion_ssh_user")"

if [[ ! "${bastion_public_dns}" =~ ^[A-Za-z0-9][A-Za-z0-9.-]*$ ]]; then
    echo "The bastion public address is not a valid DNS name" >&2
    exit 1
fi
if [[ ! "${bastion_private_dns}" =~ ^[A-Za-z0-9][A-Za-z0-9.-]*$ ]]; then
    echo "The bastion private address is not a valid DNS name" >&2
    exit 1
fi
if [[ ! "${bastion_user}" =~ ^[A-Za-z_][A-Za-z0-9_-]*$ ]]; then
    echo "The bastion SSH user is invalid" >&2
    exit 1
fi

# Ensure the random CI UID has a passwd entry before OpenSSH consults it.
if ! whoami &>/dev/null; then
    if [[ -w /etc/passwd ]]; then
        echo "${USER_NAME:-default}:x:$(id -u):0:${USER_NAME:-default} user:${HOME}:/sbin/nologin" >> /etc/passwd
    else
        echo "/etc/passwd is not writable and the current UID has no passwd entry" >&2
        exit 1
    fi
fi

ssh_private_key="${CLUSTER_PROFILE_DIR}/ssh-privatekey"
if [[ ! -s "${ssh_private_key}" ]]; then
    echo "The bastion SSH private key is missing or empty" >&2
    exit 1
fi
ssh_options=(
    -o UserKnownHostsFile=/dev/null
    -o StrictHostKeyChecking=no
    -o "IdentityFile=${ssh_private_key}"
    -o ConnectTimeout=10
    -o ConnectionAttempts=3
)
remote_cleanup_ready=true

scp "${ssh_options[@]}" "${image_archive}" \
    "${bastion_user}@${bastion_public_dns}:/home/${bastion_user}/quay-mirror.tar"
scp "${ssh_options[@]}" "${extract_dir}/quay" \
    "${bastion_user}@${bastion_public_dns}:/home/${bastion_user}/quay"

ssh "${ssh_options[@]}" "${bastion_user}@${bastion_public_dns}" \
    "sudo install -m 0755 '/home/${bastion_user}/quay' /usr/local/bin/quay &&
     sudo /usr/local/bin/quay install -hostname '${bastion_private_dns}' -data-dir /var/lib/quay -image-archive '/home/${bastion_user}/quay-mirror.tar' &&
     sudo systemctl is-active --quiet quay.service &&
     sudo curl --retry 20 --retry-delay 3 --retry-all-errors --silent --show-error --fail --cacert /var/lib/quay/ssl.cert 'https://${bastion_private_dns}:8443/healthz' >/dev/null"

ca_output_tmp="$(mktemp "${SHARED_DIR}/.mirror_registry_ca.crt.XXXXXX")"
creds_output_tmp="$(mktemp "${SHARED_DIR}/.mirror_registry_creds.XXXXXX")"
endpoint_output_tmp="$(mktemp "${SHARED_DIR}/.mirror_registry_url.XXXXXX")"

ssh "${ssh_options[@]}" "${bastion_user}@${bastion_public_dns}" \
    "sudo cat /var/lib/quay/ssl.cert" > "${ca_output_tmp}"
ssh "${ssh_options[@]}" "${bastion_user}@${bastion_public_dns}" \
    "sudo cat /var/lib/quay/auth/admin-password" > "${admin_password_file}"

tr -d '\r\n' < "${admin_password_file}" > "${normalized_password_file}"
mv -f -- "${normalized_password_file}" "${admin_password_file}"
chmod 0600 "${admin_password_file}"
if [[ ! -s "${admin_password_file}" ]]; then
    echo "The generated OMR administrator secret is empty" >&2
    exit 1
fi

{
    printf 'admin:'
    cat "${admin_password_file}"
    printf '\n'
} > "${creds_output_tmp}"
printf '%s:8443\n' "${bastion_private_dns}" > "${endpoint_output_tmp}"

if [[ ! -s "${ca_output_tmp}" ]] ||
   ! grep -q '^-----BEGIN CERTIFICATE-----$' "${ca_output_tmp}" ||
   ! grep -q '^-----END CERTIFICATE-----$' "${ca_output_tmp}"; then
    echo "The generated OMR CA certificate is invalid" >&2
    exit 1
fi
if [[ "$(wc -l < "${creds_output_tmp}")" -ne 1 ]] ||
   [[ "$(<"${endpoint_output_tmp}")" != "${bastion_private_dns}:8443" ]]; then
    echo "Generated OMR runtime material failed validation" >&2
    exit 1
fi

chmod 0644 "${ca_output_tmp}" "${endpoint_output_tmp}"
chmod 0600 "${creds_output_tmp}"

# Publish complete files atomically. The endpoint is the downstream ready marker.
mv -f -- "${ca_output_tmp}" "${ca_file}"
mv -f -- "${creds_output_tmp}" "${creds_file}"
mv -f -- "${endpoint_output_tmp}" "${endpoint_file}"
published=true

echo "OMR is healthy on the standard disconnected AWS bastion."
