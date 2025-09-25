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

# install required tools

# Install jq 
curl -sL "https://github.com/jqlang/jq/releases/latest/download/jq-linux-amd64" -o /usr/local/bin/jq 
chmod +x /usr/local/bin/jq
# Install yq (following repo pattern with proper path)
curl -L https://github.com/mikefarah/yq/releases/latest/download/yq_linux_amd64 -o /tmp/yq
chmod +x /tmp/yq 
mv /tmp/yq /usr/local/bin/yq
# Install helm (following stackrox pattern)
mkdir /tmp/helm
curl https://get.helm.sh/helm-v3.16.2-linux-amd64.tar.gz --output /tmp/helm/helm-v3.16.2-linux-amd64.tar.gz
(cd /tmp/helm && tar xvfpz helm-v3.16.2-linux-amd64.tar.gz)
cp /tmp/helm/linux-amd64/helm /usr/local/bin/helm
chmod +x /usr/local/bin/helm
rm -rf /tmp/helm

unset GOFLAGS
make infra.all deployall
