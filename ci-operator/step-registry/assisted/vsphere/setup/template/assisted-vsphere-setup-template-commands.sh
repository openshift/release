#!/bin/bash

set -o nounset
set -o errexit
set -o pipefail

echo "************ vsphere assisted test-infra setup template command ************"

# shellcheck source=/dev/null
source "${SHARED_DIR}/govc.sh"
declare vsphere_cluster
declare vsphere_portgroup

# shellcheck source=/dev/null
source "${SHARED_DIR}/vsphere_context.sh"

unset SSL_CERT_FILE
unset GOVC_TLS_CA_CERTS

echo "Data center is ${GOVC_DATACENTER}"
TEMPLATE_PATH="/${GOVC_DATACENTER}/vm/assisted-test-infra-ci/assisted-test-infra-machine-template"

# TEMPORARY - remove once the template has been rebuilt in every datacenter.
# The CI SSH key (edge-group/assisted-installer-ci) was rotated on 2026-11-17.
# Templates created before the cutoff contain the old public key, so delete them
# and let packer rebuild below. Templates created after the cutoff are kept.
TEMPLATE_KEY_CUTOFF="2026-11-17T12:00:00Z"
if govc object.collect "${TEMPLATE_PATH}" >/dev/null 2>&1; then
    template_created="$(govc vm.info -json "${TEMPLATE_PATH}" | jq -r '(.virtualMachines // .VirtualMachines)[0] | (.config // .Config) | (.createDate // .CreateDate) // empty')"
    echo "Existing template create date: ${template_created:-unknown}"
    if [[ -z "${template_created}" ]] || [[ "$(date -d "${template_created}" +%s)" -lt "$(date -d "${TEMPLATE_KEY_CUTOFF}" +%s)" ]]; then
        echo "Template predates the SSH key rotation (${TEMPLATE_KEY_CUTOFF}) - deleting it"
        govc object.destroy "${TEMPLATE_PATH}"
    fi
fi
# END TEMPORARY

if govc object.collect "${TEMPLATE_PATH}"; then
    printf 'Assisted service ci template already exist - skipping \n'
    exit 0
fi

printf 'Assisted service ci template does not exist - creating using packer\n'


SSH_PUBLIC_KEY="$(cat /var/run/vault/assisted-ci-vault/ssh_public_key)"

echo "Creating packer build path"
mkdir -p build/packer
cp -r packer_files/vsphere_centos_template/* build/packer/
cd build/packer/

echo "Get Centos Stream latest version checksum"
CENTOS_ISO="$(cat /var/run/vault/assisted-ci-vault/centos_iso_image_name)"
CENTOS_ISO_BASE_PATH="$(cat /var/run/vault/assisted-ci-vault/centos_iso_image_url)"
ISO_CHECKSUM=$(curl -s "${CENTOS_ISO_BASE_PATH}${CENTOS_ISO}.SHA256SUM" | grep "${CENTOS_ISO}" | awk -F' = ' '{print $2}' | tr -d '\n')

echo "Checksum for ${CENTOS_ISO} = ${ISO_CHECKSUM}"

echo "Create packer variables file"
cat >> vsphere-params.hcl << EOF
vsphere_server = "${GOVC_URL}"
vsphere_username = "${GOVC_USERNAME}"
vsphere_password = "${GOVC_PASSWORD}"
vsphere_datacenter = "${GOVC_DATACENTER}"
vsphere_datastore = "${GOVC_DATASTORE}"
vsphere_cluster = "${vsphere_cluster}"
vsphere_network = "${vsphere_portgroup}"
vsphere_folder = "assisted-test-infra-ci"
vm_name = "assisted-test-infra-machine-template"
ssh_public_key = "${SSH_PUBLIC_KEY}"
ssh_private_key_file = "/var/run/vault/assisted-ci-vault/ssh_private_key"
iso_url = "${CENTOS_ISO_BASE_PATH}${CENTOS_ISO}"
iso_checksum = "${ISO_CHECKSUM}"
EOF

export PACKER_CONFIG_DIR="/home/assisted-test-infra/build/packer/config"
export PACKER_CACHE_DIR="${PACKER_CONFIG_DIR}/cache"
packer.io init .
packer.io build -on-error=cleanup -var-file=vsphere-params.hcl .
