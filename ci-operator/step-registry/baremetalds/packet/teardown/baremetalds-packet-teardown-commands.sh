#!/bin/bash

set -o nounset
set -o errexit
set -o pipefail

cluster_profile=/var/run/secrets/ci.openshift.io/cluster-profile
export SSH_PRIV_KEY_PATH=${cluster_profile}/ssh-privatekey

set +x
export SSHOPTS="-o ConnectTimeout=5 -o StrictHostKeyChecking=no -o UserKnownHostsFile=/dev/null -o ServerAliveInterval=90 -i ${SSH_PRIV_KEY_PATH}"
PACKET_AUTH_TOKEN=$(cat ${cluster_profile}/.packetcred)
export PACKET_AUTH_TOKEN
set -x

echo "************ baremetalds packet teardown command ************"
env | sort

# Initial check
if [ "${CLUSTER_TYPE}" != "packet" ] ; then
    echo >&2 "Unsupported cluster type '${CLUSTER_TYPE}'"
    exit 1
fi

echo "-------[ $SHARED_DIR ]"
ls -ll ${SHARED_DIR}

# Shutdown packet server
terraform_home=${ARTIFACT_DIR}/terraform
mkdir -p ${terraform_home}
cp ${SHARED_DIR}/terraform.* ${terraform_home}
echo "Deprovisioning cluster..."
cd ${terraform_home}
terraform init
# shellcheck disable=SC2034
for r in {1..5}; do terraform destroy -auto-approve && break ; done



