#!/bin/bash

set -o nounset
set -o errexit
set -o pipefail

cluster_profile=/var/run/secrets/ci.openshift.io/cluster-profile

export CLUSTER_NAME=${NAMESPACE}-${JOB_NAME_HASH}

echo "************ baremetalds packet setup command ************"
env | sort

set +x
export PACKET_PROJECT_ID=b3c1623c-ce0b-45cf-9757-c61a71e06eac
PACKET_AUTH_TOKEN=$(cat ${cluster_profile}/.packetcred)
export PACKET_AUTH_TOKEN
set -x

# Initial check
if [ "${CLUSTER_TYPE}" != "packet" ] ; then
    echo >&2 "Unsupported cluster type '${CLUSTER_TYPE}'"
    exit 1
fi

# Terraform setup and init for packet server
terraform_home=/tmp/terraform
mkdir -p ${terraform_home}
cd ${terraform_home}

cat > ${terraform_home}/terraform.tf <<-EOF
provider "packet" {
}

resource "packet_device" "server" {
  count            = "1"
  project_id       = "$PACKET_PROJECT_ID"
  hostname         = "ipi-$CLUSTER_NAME"
  plan             = "c2.medium.x86"
  facilities       = ["sjc1", "ewr1"]
  operating_system = "centos_8"
  billing_cycle    = "hourly"
}
EOF

# Ensure files are always shared 
finished()
{
  if [[ -e ${terraform_home}/terraform.tfstate ]]
  then
    # Sharing terraform artifacts required by teardown
    cp ${terraform_home}/terraform.* ${SHARED_DIR}

    # Sharing artifacts required by other steps
    jq -r '.modules[0].resources["packet_device.server"].primary.attributes.access_public_ipv4' ${terraform_home}/terraform.tfstate > ${SHARED_DIR}/server-ip
  fi
}
trap finished EXIT TERM


terraform init

# Packet returns transients errors when creating devices.
# example, `Oh snap, something went wrong! We've logged the error and will take a look - please reach out to us if you continue having trouble.`
# therefore the terraform apply needs to be retried a few time before giving up.
rc=1
for _ in {1..5}; do terraform apply -auto-approve && rc=0 && break ; done
if test "${rc}" -eq 1; then 
  echo >&2 "Failed to create packet server"
  exit 1
fi




