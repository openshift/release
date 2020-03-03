#!/bin/bash

set -o nounset
set -o errexit
set -o pipefail

cluster_profile=/var/run/secrets/ci.openshift.io/cluster-profile
export SSH_PRIV_KEY_PATH=${cluster_profile}/ssh-privatekey

set +x
export SSHOPTS="-o ConnectTimeout=5 -o StrictHostKeyChecking=no -o UserKnownHostsFile=/dev/null -o ServerAliveInterval=90 -i ${SSH_PRIV_KEY_PATH}"
export PACKET_AUTH_TOKEN=$(cat ${cluster_profile}/.packetcred)
set -x

echo "************ baremetalds teardown command ************"
env | sort

# Initial check
if [ "${CLUSTER_TYPE}" != "packet" ] ; then
    echo >&2 "Unsupported cluster type '${CLUSTER_TYPE}'"
    exit 1
fi

# Terraform setup and teardown for packet server
### terraform_home=${ARTIFACT_DIR}/terraform
### mkdir -p ${terraform_home}
### cd ${terraform_home}

### cp ${SHARED_DIR}/terraform.* ${terraform_home}

whoami

# Logs fetching
### export IP=$(cat ${SHARED_DIR}/packet-server-ip)
export IP=147.75.69.55
if [ -n "$IP" ] ; then
   echo "Getting logs"
### ###   ssh $SSHOPTS root@$IP tar -czf - /root/dev-scripts/logs | tar -C ${ARTIFACT_DIR} -xzf -
   mkdir -p ${ARTIFACT_DIR}/dev-scripts/logs/
   scp $SSHOPTS -r root@IP:/root/dev-scripts/logs ${ARTIFACT_DIR}/dev-scripts/logs/
   sed -i -e 's/.*auths.*/*** PULL_SECRET ***/g' ${ARTIFACT_DIR}/dev-scripts/logs/*
fi

### echo "Deprovisioning cluster ..."
### terraform init
### for r in {1..5}; do terraform destroy -auto-approve && break ; done



