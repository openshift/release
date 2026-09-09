#!/bin/bash

set -o nounset
set -o errexit
set -o pipefail

sleep 8s

# The AWS terraform provider (used by the aws / awssts / S3CloudFront branches)
# has no credential source in the CI test pod: there is no IMDS role, so terraform
# destroy fails with "No valid credential sources found" and the S3 bucket leaks in
# the long-lived QE account. Export the static QE AWS credentials from the mounted
# secret, mirroring quay-deploy-aws-s3 which creates the bucket with them.
# Guarded so the gcp/azure branches are unaffected. Do not echo the key material.
if [[ -f /var/run/quay-qe-aws-secret/access_key ]]; then
    AWS_ACCESS_KEY_ID=$(cat /var/run/quay-qe-aws-secret/access_key)
    AWS_SECRET_ACCESS_KEY=$(cat /var/run/quay-qe-aws-secret/secret_key)
    export AWS_ACCESS_KEY_ID
    export AWS_SECRET_ACCESS_KEY
fi

if [[ "$QUAY_STORAGE_PROVIDER" == 'gcp' ]]; then
    #Copy GCP auth.json from mounted secret to current directory
    mkdir -p QUAY_GCP && cd QUAY_GCP
    cp /var/run/quay-qe-gcp-secret/auth.json .
    cp ${SHARED_DIR}/terraform.tgz .
    tar -xzvf terraform.tgz && ls

    QUAY_GCP_STORAGE_ID=$(cat ${SHARED_DIR}/QUAY_GCP_STORAGE_ID)
    echo "Start to destroy quay gcp bucket $QUAY_GCP_STORAGE_ID ..."

    export TF_VAR_gcp_storage_bucket="${QUAY_GCP_STORAGE_ID}"
    terraform init
    terraform destroy -auto-approve || true          
fi

if [[ "$QUAY_STORAGE_PROVIDER" == 'azure' ]]; then
    mkdir -p QUAY_AZURE && cd QUAY_AZURE
    cp ${SHARED_DIR}/terraform.tgz .
    tar -xzvf terraform.tgz && ls

    QUAY_AZURE_STORAGE_ID=$(cat ${SHARED_DIR}/QUAY_AZURE_STORAGE_ID)
    echo "Start to destroy quay azure bucket $QUAY_AZURE_STORAGE_ID ..."

    export TF_VAR_resource_group="${QUAY_AZURE_STORAGE_ID}"
    export TF_VAR_storage_account="${QUAY_AZURE_STORAGE_ID}"
    export TF_VAR_storage_container="${QUAY_AZURE_STORAGE_ID}"
    terraform init
    terraform destroy -auto-approve || true          
fi


if [[ "$QUAY_STORAGE_PROVIDER" == 'aws' ]]; then
    mkdir -p QUAY_AWS && cd QUAY_AWS
    cp ${SHARED_DIR}/terraform.tgz .
    tar -xzvf terraform.tgz && ls

    QUAY_AWS_S3_BUCKET=$(cat ${SHARED_DIR}/QUAY_AWS_S3_BUCKET)
    echo "Start to destroy quay aws bucket $QUAY_AWS_S3_BUCKET ..."

    export TF_VAR_aws_bucket="${QUAY_AWS_S3_BUCKET}"
    terraform init
    terraform destroy -auto-approve || true          
fi

if [[ "$QUAY_STORAGE_PROVIDER" == 'awssts' ]]; then
    mkdir -p QUAY_AWSSTS && cd QUAY_AWSSTS
    cp "${SHARED_DIR}/terraform.tgz" .
    tar -xzvf terraform.tgz && ls

    QUAY_AWS_S3_BUCKET=$(cat "${SHARED_DIR}/QUAY_AWS_STS_S3_BUCKET")
    randomnum=$(cat "${SHARED_DIR}/QUAY_AWS_STS_RANDOM")
    QUAY_AWS_STS_ROLE_NAME="quay_prow_role${randomnum}"
    QUAY_AWS_STS_USER="quay_prow_automation${randomnum}"
    export TF_VAR_aws_bucket="${QUAY_AWS_S3_BUCKET}"
    export TF_VAR_aws_sts_role_name="${QUAY_AWS_STS_ROLE_NAME}"
    export TF_VAR_aws_sts_user_name="${QUAY_AWS_STS_USER}"

    echo "Start to destroy quay aws sts ..."
    terraform init
    terraform destroy -auto-approve || true
fi

if [[ "$QUAY_STORAGE_PROVIDER" == 'S3CloudFront' ]]; then
    mkdir -p QUAY_S3CloundFront && cd QUAY_S3CloundFront
    cp "${SHARED_DIR}/terraform.s3cf.tgz" .
    tar -xzvf terraform.s3cf.tgz && ls

    QUAY_AWS_S3_CF_BUCKET=$(cat "${SHARED_DIR}/QUAY_AWS_S3_CF_BUCKET")
    randomnum=$(cat "${SHARED_DIR}/QUAY_AWS_CF_RANDOM")
    export TF_VAR_aws_bucket="${QUAY_AWS_S3_CF_BUCKET}"
    export TF_VAR_quay_s3_origin_id="quay_origin_id${randomnum}"

    echo "Start to destroy quay aws s3 cloudfront ..."
    terraform init
    terraform destroy -auto-approve || true
fi
