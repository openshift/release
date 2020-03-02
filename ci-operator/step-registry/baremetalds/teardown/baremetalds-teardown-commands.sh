#!/bin/bash

set -o nounset
set -o errexit
set -o pipefail

cluster_profile=/var/run/secrets/ci.openshift.io/cluster-profile
export SSH_PRIV_KEY_PATH=${cluster_profile}/ssh-privatekey

set +x
export SSHOPTS="-o ConnectTimeout=5 -o StrictHostKeyChecking=no -o UserKnownHostsFile=/dev/null -o ServerAliveInterval=90 -i ${SSH_PRIV_KEY_PATH}"
set -x

echo "************ baremetalds teardown command ************"
env | sort

# Initial check
if [ "${CLUSTER_TYPE}" != "packet" ] ; then
    echo >&2 "Unsupported cluster type '${CLUSTER_TYPE}'"
    exit 1
fi

echo "-----------------------"
mkdir -p /tmp/nss
ls -ll ${SHARED_DIR} 
cp -R ${SHARED_DIR}/nss /tmp/nss
ls -ll /tmp/nss
cat /tmp/nss/mock-nss.sh
echo "-----------------------"



# # Terraform setup and teardown for packet server
# terraform_home=${ARTIFACT_DIR}/terraform

# ls -ll ${SHARED_DIR}

# if [ ! -d ${SHARED_DIR}/terraform ]; then
#     echo >&2 "Cannot teardown packet server, terraform config files are missing"
#     exit 1
# fi

# cp -R ${SHARED_DIR}/terraform ${ARTIFACT_DIR} # Retrieving shared terraform configuration
# cd ${terraform_home}

# ls -ll


# #            if [ -n "$IP" ] ; then
# #                echo "Getting logs"
# #                ssh $SSHOPTS root@$IP tar -czf - /root/dev-scripts/logs | tar -C /tmp/artifacts -xzf -
# #                sed -i -e 's/.*auths.*/*** PULL_SECRET ***/g' /tmp/artifacts/root/dev-scripts/logs/*
# #            fi

# echo "Deprovisioning cluster ..."
# terraform init
# for r in {1..5}; do terraform destroy -auto-approve && break ; done



