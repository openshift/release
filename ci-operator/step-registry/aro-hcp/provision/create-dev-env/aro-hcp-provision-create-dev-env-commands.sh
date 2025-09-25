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

az version
az bicep install
az bicep version --only-show-errors || true

unset GOFLAGS
make infra.all deployall
