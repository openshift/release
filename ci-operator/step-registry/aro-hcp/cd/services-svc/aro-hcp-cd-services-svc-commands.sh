#!/bin/bash
set -o errexit
set -o nounset
set -o pipefail

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
export DETECT_DIRTY_GIT_WORKTREE=0

cd dev-infrastructure && make svc.aks.kubeconfig && cd ..

# Deploy each service: record-override fetches digest from ACR, then pipeline deploys
deploy_service() {
  local svc_dir=$1 pipeline_name=$2
  local override_file="/tmp/${svc_dir}-override.yaml"
  make -C "${svc_dir}/" record-override \
    OVERRIDE_CONFIG_FILE="${override_file}" \
    DETECT_DIRTY_GIT_WORKTREE=0
  make "pipeline/${pipeline_name}" OVERRIDE_CONFIG_FILE="${override_file}"
}

deploy_service backend    RP.Backend
deploy_service frontend   RP.Frontend
deploy_service admin      AdminAPI
deploy_service sessiongate SessionGate

# Non-image services (no record-override needed)
make maestro.server.deploy_pipeline
make observability.tracing.deploy_pipeline

# CSPR dressup: creates CS namespace with MSI/KV bindings, deploys cleaners
./svc-deploy.sh "${DEPLOY_ENV}" cluster-service svc deploy-pr-env-deps
