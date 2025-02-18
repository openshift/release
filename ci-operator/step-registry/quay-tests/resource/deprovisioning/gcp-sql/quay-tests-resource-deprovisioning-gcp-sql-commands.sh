#!/bin/bash

set -o nounset
set -o errexit
set -o pipefail

# Copy terraform files back from $SHARED_DIR
QUAY_GCP_SQL_TERRAFORM_PACKAGE="QUAY_GCP_SQL_TERRAFORM_PACKAGE.tgz"

echo "Copy GCP SQL terraform files back from $SHARED_DIR"
mkdir -p terraform_quay_gcp_sql && cd terraform_quay_gcp_sql
cp "${SHARED_DIR}"/$QUAY_GCP_SQL_TERRAFORM_PACKAGE .
tar -xzvf $QUAY_GCP_SQL_TERRAFORM_PACKAGE && ls

#Destroy Google cloud SQL instance
echo "Start to destroy quay gcp sql instance ..."
terraform --version
terraform init
terraform destroy -auto-approve || true
