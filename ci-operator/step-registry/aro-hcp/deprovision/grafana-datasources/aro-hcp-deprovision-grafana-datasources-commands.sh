#!/bin/bash
set -o errexit
set -o nounset
set -o pipefail

export CLUSTER_PROFILE_DIR="/var/run/aro-hcp-${VAULT_SECRET_PROFILE}"

export AZURE_CLIENT_ID; AZURE_CLIENT_ID=$(cat "${CLUSTER_PROFILE_DIR}/client-id")
export AZURE_TENANT_ID; AZURE_TENANT_ID=$(cat "${CLUSTER_PROFILE_DIR}/tenant")
export AZURE_CLIENT_SECRET; AZURE_CLIENT_SECRET=$(cat "${CLUSTER_PROFILE_DIR}/client-secret")
export AZURE_TOKEN_CREDENTIALS=prod

az login --service-principal -u "${AZURE_CLIENT_ID}" -p "${AZURE_CLIENT_SECRET}" --tenant "${AZURE_TENANT_ID}" --output none

export GLOBAL_INFRA_SUBSCRIPTION_ID; GLOBAL_INFRA_SUBSCRIPTION_ID=$(cat "${CLUSTER_PROFILE_DIR}/infra-global-subscription-id")

echo "Building grafanactl..."
go build -o /tmp/grafanactl ./tooling/grafanactl

echo "Running: grafanactl clean datasources"
/tmp/grafanactl clean datasources \
  --subscription "${GLOBAL_INFRA_SUBSCRIPTION_ID}" \
  --resource-group "${GRAFANA_RESOURCE_GROUP}" \
  --grafana-name "${GRAFANA_NAME}"

echo "Running: grafanactl clean fixup-datasources"
/tmp/grafanactl clean fixup-datasources \
  --subscription "${GLOBAL_INFRA_SUBSCRIPTION_ID}" \
  --resource-group "${GRAFANA_RESOURCE_GROUP}" \
  --grafana-name "${GRAFANA_NAME}"
