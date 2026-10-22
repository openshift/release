#!/bin/bash
set -euo pipefail

: "${SHARED_DIR:?SHARED_DIR must be set}"
: "${CLUSTER_PROFILE_DIR:?CLUSTER_PROFILE_DIR must be set}"
: "${ARTIFACT_DIR:?ARTIFACT_DIR must be set}"

echo "=== BYOH node-pool provisioning ==="

if [[ -z "${BYOH_INSTANCE_NAME:-}" ]]; then
    chars="0123456789abcdefghijklmnopqrstuvwxyz"
    suffix=""
    for _ in 1 2 3; do
        suffix+="${chars:$((RANDOM % ${#chars})):1}"
    done
    BYOH_INSTANCE_NAME="byoh-${suffix}"
fi
export BYOH_INSTANCE_NAME
export BYOH_NUM_WORKERS="${BYOH_NUM_WORKERS:-3}"
export BYOH_WINDOWS_VERSION="${BYOH_WINDOWS_VERSION:-2025}"
export BYOH_TMP_DIR="${ARTIFACT_DIR}/terraform_byoh/"
export USE_NODE_POOL=true

printf '%s\n' "${BYOH_INSTANCE_NAME}" > "${SHARED_DIR}/byoh_instance_name.txt"

if [[ ! -f "${CLUSTER_PROFILE_DIR}/ssh-publickey" ]]; then
    echo "ERROR: ${CLUSTER_PROFILE_DIR}/ssh-publickey not found" >&2
    exit 1
fi
WINC_SSH_PUBLIC_KEY="$(<"${CLUSTER_PROFILE_DIR}/ssh-publickey")"
export WINC_SSH_PUBLIC_KEY

if [[ ! -f "${CLUSTER_PROFILE_DIR}/.awscred" ]]; then
    echo "ERROR: ${CLUSTER_PROFILE_DIR}/.awscred not found" >&2
    exit 1
fi
export AWS_SHARED_CREDENTIALS_FILE="${CLUSTER_PROFILE_DIR}/.awscred"
export AWS_PROFILE=default

if [[ -f "${SHARED_DIR}/AWS_REGION" ]]; then
    AWS_REGION="$(<"${SHARED_DIR}/AWS_REGION")"
    export AWS_REGION
    export AWS_DEFAULT_REGION="${AWS_REGION}"
elif [[ -n "${AWS_DEFAULT_REGION:-}" ]]; then
    export AWS_REGION="${AWS_DEFAULT_REGION}"
else
    echo "ERROR: AWS region is missing from SHARED_DIR/AWS_REGION and AWS_DEFAULT_REGION" >&2
    exit 1
fi

if [[ -f "${SHARED_DIR}/AWS_WINDOWS_AMI" ]]; then
    AWS_WINDOWS_AMI="$(<"${SHARED_DIR}/AWS_WINDOWS_AMI")"
    export AWS_WINDOWS_AMI
fi

if ! command -v terraform >/dev/null 2>&1 || [[ ! -x /usr/local/share/byoh-provisioner/byoh.sh ]]; then
    echo "ERROR: terraform-windows-provisioner image is missing terraform or byoh.sh" >&2
    exit 1
fi

cd /usr/local/share/byoh-provisioner
terraform version -no-color
echo "Provisioning ${BYOH_NUM_WORKERS} Windows ${BYOH_WINDOWS_VERSION} hosts with USE_NODE_POOL=true"

apply_status=0
if ./byoh.sh apply "${BYOH_INSTANCE_NAME}" "${BYOH_NUM_WORKERS}" "" "${BYOH_WINDOWS_VERSION}"; then
    echo "BYOH node-pool provisioning completed"
else
    apply_status=$?
    echo "ERROR: byoh.sh apply failed with status ${apply_status}; checking for partial Terraform state" >&2
fi

# This AWS UPI workflow is platform=none. Archive state before handling an
# apply failure so the post chain can destroy any instances Terraform created.
terraform_dir="${BYOH_TMP_DIR}none"
if [[ ! -d "${terraform_dir}" ]]; then
    echo "ERROR: Terraform directory not found at ${terraform_dir}" >&2
    ls -la "${BYOH_TMP_DIR}" || true
    if [[ "${apply_status}" -ne 0 ]]; then
        exit "${apply_status}"
    fi
    exit 1
fi

archive="${SHARED_DIR}/terraform_byoh_none.tar"
if tar -cf "${archive}" -C "${terraform_dir}" --exclude='.terraform' .; then
    echo "Terraform state archived to ${archive}"
    ls -lh "${archive}"
else
    archive_status=$?
    echo "ERROR: Failed to archive Terraform state from ${terraform_dir}" >&2
    exit "${archive_status}"
fi

if [[ "${apply_status}" -ne 0 ]]; then
    echo "ERROR: State was archived for teardown, but BYOH provisioning failed" >&2
    exit "${apply_status}"
fi
