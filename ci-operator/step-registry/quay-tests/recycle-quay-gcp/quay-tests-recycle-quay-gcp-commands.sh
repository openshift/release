#!/bin/bash

set -o nounset
set -o errexit
set -o pipefail

GCP_ACCESS_KEY=$(cat /var/run/quay-qe-gcp-secret/access_key)
GCP_SECRET_KEY=$(cat /var/run/quay-qe-gcp-secret/secret_key)

cp ${SHARED_DIR}/terraform.tgz .
tar -xzvf terraform.tgz && ls
QUAY_GCP_STORAGE_ID=$(cat ${SHARED_DIR}/QUAY_GCP_STORAGE_ID)

export TF_VAR_gcp_storage_bucket="${QUAY_GCP_STORAGE_ID}"
terraform init
terraform destroy -auto-approve || true
