#!/bin/bash
export HOME WORKSPACE
HOME=/tmp
WORKSPACE=$(pwd)
cd /tmp || exit

echo "OC_CLIENT_VERSION: $OC_CLIENT_VERSION"

export GITHUB_ORG_NAME GITHUB_REPOSITORY_NAME NAME_SPACE TAG_NAME

GITHUB_ORG_NAME="redhat-developer"
GITHUB_REPOSITORY_NAME="rhdh"
TAG_NAME="next"

# Clone and checkout the specific PR
git clone "https://github.com/${GITHUB_ORG_NAME}/${GITHUB_REPOSITORY_NAME}.git"
cd rhdh || exit

# use kubeconfig from mapt
permissions=$(stat -c "%a" "${SHARED_DIR}/kubeconfig")
if  [[ $permissions == 600 ]]; then
  echo "kubeconfig already has permissions 600"
else
  echo "setting kubeconfig permissions to 600"
  chmod 600 "${SHARED_DIR}/kubeconfig"
fi
KUBECONFIG="${SHARED_DIR}/kubeconfig"
export KUBECONFIG

K8S_CLUSTER_URL=$(kubectl config view --minify -o jsonpath='{.clusters[0].cluster.server}')
echo "K8S_CLUSTER_URL: $K8S_CLUSTER_URL"
kubectl config set-context --current --namespace=default
kubectl create serviceaccount tester-sa-2
kubectl create clusterrolebinding tester-sa-2-binding \
  --clusterrole=cluster-admin \
  --serviceaccount=default:tester-sa-2
K8S_CLUSTER_TOKEN=$(kubectl create token tester-sa-2)
export K8S_CLUSTER_URL K8S_CLUSTER_TOKEN

bash ./.ibm/pipelines/openshift-ci-tests.sh
