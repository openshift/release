#!/bin/bash

set -o nounset
set -o errexit
set -o pipefail

echo "************ vsphere assisted test-infra setup machine command ************"

declare vsphere_cluster
declare vsphere_portgroup

# shellcheck source=/dev/null
source "${SHARED_DIR}/vsphere_context.sh"

# Ensures that the vsphere template exists.
# shellcheck source=/dev/null
source "${SHARED_DIR}/govc.sh"

unset SSL_CERT_FILE
unset GOVC_TLS_CA_CERTS

mkdir -p build/govc
export GOVMOMI_HOME=/home/assisted-test-infra/build/govc/
govc object.collect "/${GOVC_DATACENTER}/vm/assisted-test-infra-ci/assisted-test-infra-machine-template" || { echo 'Assisted service ci template does not exist' ; exit 1; }

# Cloning the template into a new CI VM.
mkdir -p /home/assisted-test-infra/build/terraform
cp -r terraform_files/vsphere-ci-machine/* /home/assisted-test-infra/build/terraform/
cd /home/assisted-test-infra/build/terraform

# Create variables file
cat >> vsphere-params.hcl << EOF
vsphere_server = "${GOVC_URL}"
vsphere_username = "${GOVC_USERNAME}"
vsphere_password = "${GOVC_PASSWORD}"
vsphere_datacenter = "${GOVC_DATACENTER}"
vsphere_datastore = "${GOVC_DATASTORE}"
vsphere_cluster = "${vsphere_cluster}"
vsphere_network = "${vsphere_portgroup}"
template_name = "assisted-test-infra-machine-template"
build_id = "${BUILD_ID}"
EOF

export TF_LOG=DEBUG
terraform init -input=false -no-color
terraform apply -var-file=vsphere-params.hcl -input=false -auto-approve -no-color
IP=$(terraform output ip_address)
PORT=${VSPHERE_SSH_PORT:-22}

cd ..
tar -cvzf terraform.tgz --exclude=".terraform" /home/assisted-test-infra/build/terraform
cp terraform.tgz ${SHARED_DIR}

cat > "${SHARED_DIR}/ci-machine-config.sh" << EOF
export IP="${IP}"
export SSH_KEY_FILE=/var/run/vault/assisted-ci-vault/ssh_private_key
export SSH_USER="root"
export SSH_PORT="${PORT}"
SSHOPTS=(
  -o Port=${PORT}
  -o 'ConnectTimeout=5'
  -o 'StrictHostKeyChecking=no'
  -o 'UserKnownHostsFile=/dev/null'
  -o 'ServerAliveInterval=90'
  -o LogLevel=ERROR
  -i "/var/run/vault/assisted-ci-vault/ssh_private_key"
)
EOF

chmod 0600 "${SHARED_DIR}/ci-machine-config.sh"
