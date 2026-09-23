#!/bin/bash
set -o errexit
set -o nounset
set -o pipefail

export CLUSTER_PROFILE_DIR="/var/run/aro-hcp-${VAULT_SECRET_PROFILE}"

export AZURE_CLIENT_ID; AZURE_CLIENT_ID=$(cat "${CLUSTER_PROFILE_DIR}/client-id")
export AZURE_TENANT_ID; AZURE_TENANT_ID=$(cat "${CLUSTER_PROFILE_DIR}/tenant")
export AZURE_CLIENT_SECRET; AZURE_CLIENT_SECRET=$(cat "${CLUSTER_PROFILE_DIR}/client-secret")
export AZURE_SUBSCRIPTION_ID; AZURE_SUBSCRIPTION_ID=$(cat "${CLUSTER_PROFILE_DIR}/infra-subscription-id")

az login --service-principal \
  -u "${AZURE_CLIENT_ID}" \
  -p "${AZURE_CLIENT_SECRET}" \
  --tenant "${AZURE_TENANT_ID}" \
  --output none

az account set --subscription "${AZURE_SUBSCRIPTION_ID}"

export DEPLOY_ENV="${DEPLOY_ENV:-cspr}"
export SKIP_CONFIRM=true
export PERSIST=true
export AZURE_TOKEN_CREDENTIALS="${AZURE_TOKEN_CREDENTIALS:-dev}"
export PRINCIPAL_ID; PRINCIPAL_ID=$(az ad sp show --id "${AZURE_CLIENT_ID}" --query id -o tsv)

# Build one shared image override from the ci-operator pipeline dependencies.
# shellcheck source=/dev/null
source hack/ci/build-config-override.sh

# The shared helper also optimizes lease-less healthcheck clusters. CSPR is a
# persistent environment, so retain the node count from its normal config.
yq eval -i "
  del(.clouds.dev.environments.${DEPLOY_ENV}.defaults.mgmt.aks.userAgentPool.minCount)
" "${OVERRIDE_CONFIG_FILE}"

run_pipeline() {
    make "pipeline/$1" \
      DEPLOY_ENV="${DEPLOY_ENV}" \
      OVERRIDE_CONFIG_FILE="${OVERRIDE_CONFIG_FILE}" \
      STEP_CACHE_DIR=
}

# Follow the Region topology explicitly so CSPR can omit Cluster Service.
run_pipeline Region
run_pipeline Service.Infra

make -C dev-infrastructure svc.aks.admin-access
make -C dev-infrastructure svc.cs-pr-check-msi
make -C dev-infrastructure svc.aks.kubeconfig

run_pipeline Maestro.Server
# Microsoft.Azure.ARO.HCP.ClusterService is intentionally omitted for CSPR.
run_pipeline RP.Backend
run_pipeline RP.Frontend
run_pipeline SessionGate
run_pipeline AdminAPI
run_pipeline Fleet

# Create the CSPR Cluster Service namespace and its MSI/Key Vault bindings
# without deploying the Cluster Service pipeline itself.
./svc-deploy.sh "${DEPLOY_ENV}" cluster-service svc deploy-pr-env-deps

run_pipeline Management.Infra
make -C dev-infrastructure mgmt.aks.admin-access
make -C dev-infrastructure mgmt.aks.kubeconfig

run_pipeline Velero
run_pipeline SecretSyncController
run_pipeline ACM
run_pipeline RP.HypershiftOperator
run_pipeline Maestro.Agent
run_pipeline KubeApplier
run_pipeline MgmtAgent
run_pipeline Fleet.Registration

run_pipeline Monitoring

# Observability is a dev-only stamped pipeline outside the Region topology.
run_pipeline Observability
