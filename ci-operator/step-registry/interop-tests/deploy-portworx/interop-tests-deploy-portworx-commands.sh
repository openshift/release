#!/bin/bash

set -o nounset
set -o errexit
set -o pipefail

CONSOLE_URL=$(cat $SHARED_DIR/console.url)
API_URL="https://api.${CONSOLE_URL#"https://console-openshift-console.apps."}:6443"
export CONSOLE_URL
export API_URL
export overwrite_reports=false
export KUBECONFIG=$SHARED_DIR/kubeconfig

# login for interop
if test -f ${SHARED_DIR}/kubeadmin-password; then
  OCP_CRED_USR="kubeadmin"
  export OCP_CRED_USR
  OCP_CRED_PSW="$(cat ${SHARED_DIR}/kubeadmin-password)"
  export OCP_CRED_PSW
  oc login -u kubeadmin -p "$(cat $SHARED_DIR/kubeadmin-password)" ${API_URL} --insecure-skip-tls-verify=true
  echo "oc login -u kubeadmin -p $(cat $SHARED_DIR/kubeadmin-password) ${API_URL} --insecure-skip-tls-verify=true"
else
  eval "$(cat "${SHARED_DIR}/api.login")"
  echo "$(cat "${SHARED_DIR}/api.login")"
fi

SECRETS_DIR="/tmp/secrets/ci"
ESSENTIAL_ENTITLEMENT_ID="$(cat ${SECRETS_DIR}/essential-id)" || true
export ESSENTIAL_ENTITLEMENT_ID

AWS_ACCESS_KEY_ID=$(grep "aws_access_key_id="  "${CLUSTER_PROFILE_DIR}/.awscred" | cut -d '=' -f2)
AWS_SECRET_ACCESS_KEY=$(grep "aws_secret_access_key="  "${CLUSTER_PROFILE_DIR}/.awscred" | cut -d '=' -f2)
export AWS_ACCESS_KEY_ID
export AWS_SECRET_ACCESS_KEY

cd /tmp && \
  git clone -b h-cnv https://github.com/liswang89/cnv-qe.git && \
  chmod -R 777 ./cnv-qe && \
  cd cnv-qe

echo "Setup AWS_REGION and Security Group for ROSA HyperShift..."
if [ -f ${SHARED_DIR}/kubeadmin-password ]; then
  AWS_REGION="us-east-1"
  export AWS_REGION
else
  echo "start testing"
  AWS_REGION="us-west-2"
  export AWS_REGION
  ./storage-classes/portworx/setup_securitygroup.sh
fi

echo "Setup portworx..."
./storage-classes/portworx/setup_portworx.sh || true

echo "Deploy portworx operator..."
./storage-classes/portworx/install_operator.sh

echo "Deploy storagecluster..."
./storage-classes/portworx/deploy_storagecluster.sh || true

sleep 3600

echo "End of deploying portworx operator..."