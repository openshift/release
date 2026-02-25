#!/bin/bash

set -o nounset
set -o errexit
set -o pipefail

echo "************ telco5g delete-interface command ************"

# Check if the add-interface step left state for us
if [[ ! -f "${SHARED_DIR}/telco5g-instance-id" || ! -f "${SHARED_DIR}/telco5g-aws-region" ]]; then
  echo "No terraform state from telco5g-add-interface found, skipping cleanup"
  exit 0
fi

MASTER_INSTANCE_ID=$(cat "${SHARED_DIR}/telco5g-instance-id")
AWS_REGION=$(cat "${SHARED_DIR}/telco5g-aws-region")
echo "Destroying resources for instance ${MASTER_INSTANCE_ID} in ${AWS_REGION}"

# Use AWS credentials from the cluster profile
export AWS_SHARED_CREDENTIALS_FILE="${CLUSTER_PROFILE_DIR}/.awscred"

# Install terraform
TERRAFORM_VERSION="1.5.5"
curl -sL "https://releases.hashicorp.com/terraform/${TERRAFORM_VERSION}/terraform_${TERRAFORM_VERSION}_linux_amd64.zip" -o /tmp/terraform.zip
unzip -o /tmp/terraform.zip -d /tmp/
chmod +x /tmp/terraform
export PATH="/tmp:${PATH}"
terraform version

cd ${SHARED_DIR}
terraform init
terraform destroy -auto-approve -var="instance_id=${MASTER_INSTANCE_ID}"
