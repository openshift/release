#!/bin/bash
# Create an ARO HCP Cluster + Node pool using bicep.
set -o errexit
set -o nounset
set -o pipefail

unset GOFLAGS
make -C test/

export AZURE_CLIENT_ID; AZURE_CLIENT_ID=$(cat /var/run/hcp-integration-credentials/client-id)
export AZURE_CLIENT_SECRET; AZURE_CLIENT_SECRET=$(cat /var/run/hcp-integration-credentials/client-secret)
export AZURE_TENANT_ID; AZURE_TENANT_ID=$(cat /var/run/hcp-integration-credentials/tenant)

./test/aro-hcp-tests run-suite integration/parallel
