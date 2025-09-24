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

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck disable=SC1091
source "${SCRIPT_DIR}/../../common/lib/host-contract/assisted-common-lib-host-contract-commands.sh"

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

terraform init -input=false
terraform apply -var-file=nutanix-params.hcl -input=false -auto-approve
IP=$(terraform output ip_address)

cd ..
tar -cvzf terraform.tgz --exclude=".terraform" /home/assisted-test-infra/build/terraform
cp terraform.tgz ${SHARED_DIR}

host_contract::writer::begin
host_contract::writer::set HOST_PROVIDER "nutanix"
host_contract::writer::set HOST_PRIMARY_IP "$IP"
host_contract::writer::set HOST_PRIMARY_SSH_USER "root"
host_contract::writer::set HOST_PRIMARY_SSH_KEY_PATH "/var/run/vault/assisted-ci-vault/ssh_private_key"
host_contract::writer::set HOST_PRIMARY_SSH_ADDITIONAL_OPTIONS "-o ConnectTimeout=5 -o StrictHostKeyChecking=no -o UserKnownHostsFile=/dev/null -o ServerAliveInterval=90 -o LogLevel=ERROR"
host_contract::writer::commit
