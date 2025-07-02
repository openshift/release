#!/bin/bash

set -o errexit
set -o pipefail

cd /tmp
pwd

<<<<<<< HEAD
OUTPUT_FILE="/tmp/deletedcluster-logs"
IP_JUMPHOST=128.168.131.205
# Define SSH command just like Power script
SSH_CMD=$(cat <<EOF
set -e


cd /root/ocp-cluster-ibmcloud/ibmcloud-openshift-provisioning
./delete-cluster.sh
EOF
)


ssh root@$IP_JUMPHOST "$SSH_CMD" > "$OUTPUT_FILE"
=======
# install kubectl
curl -LO "https://dl.k8s.io/release/$(curl -L -s https://dl.k8s.io/release/stable.txt)/bin/linux/amd64/kubectl"
chmod +x kubectl

SECRET_DIR="/tmp/vault/ibmz-ci-creds"
PRIVATE_KEY_FILE="${SECRET_DIR}/IPI_SSH_KEY"

# https://docs.ci.openshift.org/docs/architecture/step-registry/#sharing-data-between-steps
KUBECONFIG_FILE="${SHARED_DIR}/kubeconfig"

CLUSTER_NAME=$(KUBECONFIG="$KUBECONFIG_FILE" ./kubectl config view --minify -o jsonpath='{.clusters[].name}')

SSH_KEY_PATH="/tmp/id_rsa"
SSH_ARGS="-i ${SSH_KEY_PATH} -o MACs=hmac-sha2-256 -o StrictHostKeyChecking=no -o LogLevel=ERROR -o UserKnownHostsFile=/dev/null"
if [[ $FIPS_ENABLED == true ]]; then
    SSH_CMD="manage-cluster.sh release --fips --name ${CLUSTER_NAME}"
else
    SSH_CMD="manage-cluster.sh release --name ${CLUSTER_NAME}"
fi

# setup ssh key
cp -f $PRIVATE_KEY_FILE $SSH_KEY_PATH
chmod 400 $SSH_KEY_PATH

# release a ocp cluster
ssh $SSH_ARGS root@128.168.131.205 "$SSH_CMD" > $KUBECONFIG_FILE
>>>>>>> new-origin/ibmz-ci-cluster-creation
