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

# Applying NSS fix for SSH connection
export HOME=/tmp/nss_wrapper
mkdir -p $HOME
cp ${SHARED_DIR}/libnss_wrapper.so ${HOME}
cp ${SHARED_DIR}/mock-nss.sh ${HOME}
export NSS_WRAPPER_PASSWD=$HOME/passwd NSS_WRAPPER_GROUP=$HOME/group NSS_USERNAME=nsswrapper NSS_GROUPNAME=nsswrapper LD_PRELOAD=${HOME}/libnss_wrapper.so
bash ${HOME}/mock-nss.sh

# Get dev-scripts logs
export IP=$(cat ${SHARED_DIR}/packet-server-ip)
if [ -n "$IP" ] ; then
   echo "Getting logs"
   ssh $SSHOPTS root@$IP tar -czf - /root/dev-scripts/logs | tar -C ${ARTIFACT_DIR} -xzf -
   sed -i -e 's/.*auths.*/*** PULL_SECRET ***/g' ${ARTIFACT_DIR}/root/dev-scripts/logs/*
fi

# Shutdown packet server
terraform_home=${ARTIFACT_DIR}/terraform
mkdir -p ${terraform_home}
cp ${SHARED_DIR}/terraform.* ${terraform_home}
echo "Deprovisioning cluster..."
cd ${terraform_home}
terraform init
for r in {1..5}; do terraform destroy -auto-approve && break ; done



