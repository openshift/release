#!/bin/bash

set -o nounset
set -o errexit
set -o pipefail

sleep 8h

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
