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

# Add to PATH
export PATH="/tmp/tools:$PATH"
export USER="cide"
PRINCIPAL_ID=$(az ad sp show --id "${TEST_USER_CLIENT_ID}" --query id -o tsv)
export PRINCIPAL_ID
unset GOFLAGS
make install-tools
PATH=$(go env GOPATH)/bin:$PATH
export PATH
make infra.svc.clean
make infra.mgmt.clean
make infra.region.clean