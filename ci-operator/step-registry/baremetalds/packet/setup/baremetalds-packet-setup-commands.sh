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

case "${JOB_TYPE}" in 

  presubmit)
    prow_job_url="https://prow.svc.ci.openshift.org/view/gcs/origin-ci-test/pr-logs/pull/${REPO_OWNER}_${REPO_NAME}/${PULL_NUMBER}/${JOB_NAME}/${BUILD_ID}"
    ;;

  periodic)
    prow_job_url="https://prow.svc.ci.openshift.org/view/gcs/origin-ci-test/logs/${JOB_NAME}/${BUILD_ID}"
    ;;

  *)
    prow_job_url="<none>"
    ;;
esac

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
  tags             = ["prow_job_id=$PROW_JOB_ID", "leased_resource=$LEASED_RESOURCE", "prow_job_url=$prow_job_url"]
}
EOF

terraform init

# Packet returns transients errors when creating devices.
# example, `Oh snap, something went wrong! We've logged the error and will take a look - please reach out to us if you continue having trouble.`
# therefore the terraform apply needs to be retried a few time before giving up.
rc=1
# shellcheck disable=SC20347
for _ in {1..5}; do terraform apply -auto-approve && rc=0 && break ; done
if test "${rc}" -eq 1; then 
  echo >&2 "Failed to create packet server"
  exit 1
fi

# Sharing terraform artifacts required by teardown
cp ${terraform_home}/terraform.* ${SHARED_DIR}

# Sharing artifacts required by other steps, works with terraform 0.11
jq -r '.modules[0].resources["packet_device.server"].primary.attributes.access_public_ipv4' terraform.tfstate > /tmp/server-ip

#temporary workaround for terraform 0.12
if [[ $(< /tmp/server-ip) == "null" ]] ; then
  jq -r '.resources[0].instances[0].attributes.access_public_ipv4' terraform.tfstate > /tmp/server-ip
fi
cp /tmp/server-ip ${SHARED_DIR}



