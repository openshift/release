#!/bin/bash

set -o nounset
set -o errexit
set -o pipefail

echo "************ nutanix assisted test-infra setup machine command ************"

# ensure LEASED_RESOURCE is set
if [[ -z "${LEASED_RESOURCE}" ]]; then
  echo "Failed to acquire lease"
  exit 1
fi

# shellcheck source=/dev/random
source $SHARED_DIR/nutanix_context.sh
# shellcheck source=/dev/random
source $SHARED_DIR/platform-conf.sh

mkdir -p /home/assisted-test-infra/build/terraform
cp -r terraform_files/nutanix-ci-machine/* /home/assisted-test-infra/build/terraform/
cd /home/assisted-test-infra/build/terraform

# Create variables file
cat >> nutanix-params.hcl << EOF
nutanix_username = "${NUTANIX_USERNAME}"
nutanix_password = "${NUTANIX_PASSWORD}"
nutanix_endpoint = "${NUTANIX_ENDPOINT}"
nutanix_port = "${NUTANIX_PORT}"
nutanix_cluster = "${NUTANIX_CLUSTER_NAME}"
nutanix_subnet = "${NUTANIX_SUBNET_NAME}"
iso_name = "assisted-test-infra-machine-template"
build_id = "${BUILD_ID}"
EOF

# Terraform Params
# move to new ENV value with auto load
export CI_CREDENTIALS_DIR=/var/run/vault/assisted-ci-vault

for file in $CI_CREDENTIALS_DIR/TF_VAR_*; do
   if [[  "$file" == *"TF_VAR_"* ]]; then
     key=$(basename -- $file)
     export $key="$(cat $file)"
   fi
done


terraform init -input=false
terraform apply -var-file=nutanix-params.hcl -input=false -auto-approve
IP=$(terraform output ip_address)

cd ..
tar -cvzf terraform.tgz --exclude=".terraform" /home/assisted-test-infra/build/terraform
cp terraform.tgz ${SHARED_DIR}

cat >> "${SHARED_DIR}/ci-machine-config.sh" << EOF
export IP="${IP}"
export SSH_KEY_FILE=/var/run/vault/assisted-ci-vault/ssh_private_key
EOF
