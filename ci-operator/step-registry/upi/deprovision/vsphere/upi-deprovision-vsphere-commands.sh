#!/bin/bash

set -o nounset
set -o errexit
set -o pipefail

trap 'CHILDREN=$(jobs -p); if test -n "${CHILDREN}"; then kill ${CHILDREN} && wait; fi' TERM

# TODO:
# Worse case scenario tear down
# Use govc to remove virtual machines if terraform fails

export HOME=/tmp
export AWS_SHARED_CREDENTIALS_FILE=${CLUSTER_PROFILE_DIR}/.awscred
export AWS_DEFAULT_REGION=us-east-1
export AWS_MAX_ATTEMPTS=7
export AWS_RETRY_MODE=adaptive

installer_dir=/tmp/installer
tfvars_path=/var/run/secrets/ci.openshift.io/cluster-profile/vmc.secret.auto.tfvars
cluster_name=$(<"${SHARED_DIR}"/clustername.txt)

if ! command -v aws &> /dev/null
then
    echo "$(date -u --rfc-3339=seconds) - Install AWS cli..."
    export PATH="${HOME}/.local/bin:${PATH}"
    easy_install --user pip  # our Python 2.7.5 is even too old for ensurepip
    pip install --user awscli
fi

echo "$(date -u --rfc-3339=seconds) - Remove S3 bucket..."
aws s3 rb "s3://${cluster_name}" --force

echo "$(date -u --rfc-3339=seconds) - Copying config from shared dir..."

mkdir -p "${installer_dir}/auth"
pushd ${installer_dir}

cp -t "${installer_dir}" \
    "${SHARED_DIR}/install-config.yaml" \
    "${SHARED_DIR}/metadata.json" \
    "${SHARED_DIR}/terraform.tfvars" \
    "${SHARED_DIR}/bootstrap.ign" \
    "${SHARED_DIR}/worker.ign" \
    "${SHARED_DIR}/master.ign"

cp -t "${installer_dir}/auth" \
    "${SHARED_DIR}/kubeadmin-password" \
    "${SHARED_DIR}/kubeconfig"

# Copy sample UPI files
cp -rt "${installer_dir}" \
    /var/lib/openshift-install/upi/"${CLUSTER_TYPE}"/*

# Copy secrets to terraform path
cp -t "${installer_dir}" \
    ${tfvars_path}

tar -xf "${SHARED_DIR}/terraform_state.tar.xz"

rm -rf .terraform || true
terraform init -input=false -no-color
# In some instances either the IPAM records or AWS DNS records
# are removed before teardown is executed causing terraform destroy
# to fail - this is causing resource leaks. Do not refresh the state.
terraform destroy -refresh=false -auto-approve -no-color &
wait "$!"

