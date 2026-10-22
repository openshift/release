#!/bin/bash
set -euo pipefail

: "${SHARED_DIR:?SHARED_DIR must be set}"
: "${CLUSTER_PROFILE_DIR:?CLUSTER_PROFILE_DIR must be set}"
: "${ARTIFACT_DIR:?ARTIFACT_DIR must be set}"

echo "=== BYOH node-pool teardown ==="

instance_file="${SHARED_DIR}/byoh_instance_name.txt"
if [[ ! -f "${instance_file}" ]]; then
    echo "ERROR: Instance name file not found at ${instance_file}" >&2
    exit 1
fi
BYOH_INSTANCE_NAME="$(<"${instance_file}")"
export BYOH_INSTANCE_NAME
export BYOH_NUM_WORKERS="${BYOH_NUM_WORKERS:-3}"
export BYOH_WINDOWS_VERSION="${BYOH_WINDOWS_VERSION:-2022}"
export BYOH_TMP_DIR="${ARTIFACT_DIR}/terraform_byoh/"
export USE_NODE_POOL=true

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

archive=""
for candidate in aws azure gcp vsphere nutanix none; do
    if [[ -f "${SHARED_DIR}/terraform_byoh_${candidate}.tar" ]]; then
        archive="${SHARED_DIR}/terraform_byoh_${candidate}.tar"
        platform="${candidate}"
        break
    fi
done
if [[ -z "${archive}" ]]; then
    echo "ERROR: No Terraform state archive found in ${SHARED_DIR}" >&2
    ls -la "${SHARED_DIR}" || true
    exit 1
fi

terraform_dir="${BYOH_TMP_DIR}${platform}"
mkdir -p "${terraform_dir}"
tar -xf "${archive}" -C "${terraform_dir}"

state_file="${terraform_dir}/terraform.tfstate"
if [[ ! -f "${state_file}" ]]; then
    echo "ERROR: Terraform state not found at ${state_file}" >&2
    exit 1
fi

if [[ ! -x /usr/local/share/byoh-provisioner/byoh.sh ]]; then
    echo "ERROR: byoh.sh is missing from terraform-windows-provisioner image" >&2
    exit 1
fi

terraform -chdir="${terraform_dir}" init -input=false -no-color
cd /usr/local/share/byoh-provisioner
./byoh.sh destroy "${BYOH_INSTANCE_NAME}" "${BYOH_NUM_WORKERS}" "" "${BYOH_WINDOWS_VERSION}"
echo "BYOH node-pool teardown completed"
