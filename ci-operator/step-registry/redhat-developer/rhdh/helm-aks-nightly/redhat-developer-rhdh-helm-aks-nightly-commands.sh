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
cd "${GITHUB_REPOSITORY_NAME}" || exit

# use kubeconfig from mapt
chmod 600 "${SHARED_DIR}/kubeconfig"
KUBECONFIG="${SHARED_DIR}/kubeconfig"
export KUBECONFIG

# Create a service account and assign cluster url and token
SA_NAME="tester-sa-2"
SA_NAMESPACE="default"
SA_BINDING_NAME="${SA_NAME}-binding"
if ! kubectl get serviceaccount ${SA_NAME} -n ${SA_NAMESPACE} &> /dev/null; then
  echo "Creating service account ${SA_NAME}..."
  kubectl create serviceaccount ${SA_NAME} -n ${SA_NAMESPACE}
  echo "Creating cluster role binding..."
  kubectl create clusterrolebinding ${SA_BINDING_NAME} \
      --clusterrole=cluster-admin \
      --serviceaccount=${SA_NAMESPACE}:${SA_NAME}
  echo "Service account and binding created successfully"
else
  echo "Service account ${SA_NAME} already exists in namespace ${SA_NAMESPACE}"
fi
K8S_CLUSTER_TOKEN=$(kubectl create token tester-sa-2 -n default)
K8S_CLUSTER_URL=$(kubectl config view --minify -o jsonpath='{.clusters[0].cluster.server}')
export K8S_CLUSTER_TOKEN K8S_CLUSTER_URL

bash ./.ibm/pipelines/openshift-ci-tests.sh
