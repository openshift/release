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

#Destroy Google cloud SQL instance, Terrform destroy issue:"Error, failed to deleteuser ..." 
#https://github.com/hashicorp/terraform-provider-google/issues/3820, https://github.com/concourse/infrastructure/issues/13
echo "Start to destroy quay gcp sql instance ..."
terraform --version
terraform init
terraform state list

# Run terraform destroy and capture exit status
# if ! terraform destroy -auto-approve; then
  echo "Start to destroy quay GCP SQL instance"
if ! terraform destroy -auto-approve; then
  # Wait before retrying
#   sleep 1m

  # Check if google_sql_user exists in state before removing
  if terraform state list | grep -q "google_sql_user.users"; then
    terraform state rm google_sql_user.users
  fi
  if terraform state list | grep -q "google_sql_database.database"; then
     terraform state rm google_sql_database.database
  fi


  # Try destroying again

    echo "Failed to destroy quay GCP SQL instance"
    oc delete quayregistry quay -n quay-enterprise
    sleep 2m
    terraform destroy -auto-approve || true
fi

echo "Destroy GCP SQL instance finished"





