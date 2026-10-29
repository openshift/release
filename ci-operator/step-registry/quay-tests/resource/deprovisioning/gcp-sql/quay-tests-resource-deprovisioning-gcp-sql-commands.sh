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

#Destroy Google cloud SQL instance, two problems here:
#1, Terrform destroy issue: "Error, failed to deleteuser, ... ,cannot be dropped because some objects depend on it"
#https://github.com/hashicorp/terraform-provider-google/issues/3820, https://github.com/concourse/infrastructure/issues/13
#2, After workaround #1, there is another problem: "Error when reading or editing Database: googleapi: Error 400: Invalid request: failed to delete database"

echo "Start to destroy Google Cloud SQL instance ..."
terraform --version
terraform init
terraform state list

# Workaround to avoid #1,#2 issues
if terraform state list | grep -q "google_sql_user.users"; then
    terraform state rm google_sql_user.users
fi
if terraform state list | grep -q "google_sql_database.database"; then
    terraform state rm google_sql_database.database
fi

# Run terraform destroy and capture exit status
echo "Start to destroy GCP SQL instance"
terraform destroy -auto-approve && echo "Destroy GCP SQL instance successfully" || {

  # Retry destroy GCP SQL instance if failed
  echo "Failed to destroy GCP SQL instance"
  # Remove Quay registry to close connections to GCP SQL instance
  oc delete quayregistry quay -n quay-enterprise || true
  sleep 3m
  
  # Retry terraform destroy
  terraform destroy -auto-approve || true
}
echo "Destroy GCP SQL instance finished"
