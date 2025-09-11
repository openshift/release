#!/bin/bash
# Create an ARO HCP Cluster + Node pool using bicep.
set -o errexit
set -o nounset
set -o pipefail

set -x # Turn on command tracing

# read the secrets and login as the user
export TEST_USER_CLIENT_ID; TEST_USER_CLIENT_ID=$(cat /var/run/hcp-integration-credentials/client-id)
export TEST_USER_CLIENT_SECRET; TEST_USER_CLIENT_SECRET=$(cat /var/run/hcp-integration-credentials/client-secret)
export TEST_USER_TENANT_ID; TEST_USER_TENANT_ID=$(cat /var/run/hcp-integration-credentials/tenant)
az login --service-principal -u "${TEST_USER_CLIENT_ID}" -p "${TEST_USER_CLIENT_SECRET}" --tenant "${TEST_USER_TENANT_ID}"
az bicep install
az bicep version
az account set --subscription "${CUSTOMER_SUBSCRIPTION}"
az account show
az config set core.disable_confirm_prompt=true

# install required tools

# Create tools directory
mkdir -p /tmp/tools
# installs kubectl and kubelogin
az aks install-cli --install-location /tmp/tools/kubectl --kubelogin-install-location /tmp/tools/kubelogin
/tmp/tools/kubectl version
/tmp/tools/kubelogin --version
# Install jq
curl -sL "https://github.com/jqlang/jq/releases/latest/download/jq-linux-amd64" -o /tmp/tools/jq
chmod +x /tmp/tools/jq
# Install yq  
curl -L https://github.com/mikefarah/yq/releases/latest/download/yq_linux_amd64 -o /tmp/tools/yq
chmod +x /tmp/tools/yq
# Install helm
curl https://get.helm.sh/helm-v3.16.2-linux-amd64.tar.gz -o /tmp/helm.tar.gz
tar -xzf /tmp/helm.tar.gz -C /tmp
cp /tmp/linux-amd64/helm /tmp/tools/helm
chmod +x /tmp/tools/helm
rm -rf /tmp/helm.tar.gz /tmp/linux-amd64
# Add to PATH
export PATH="/tmp/tools:$PATH"

export USER="cide"
export PRINCIPAL_ID=$(az ad sp show --id "${TEST_USER_CLIENT_ID}" --query id -o tsv)

unset GOFLAGS
make infra.svc.clean
make infra.mgmt.clean
make infra.region.clean