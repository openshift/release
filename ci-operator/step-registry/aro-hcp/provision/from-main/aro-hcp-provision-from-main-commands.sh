#!/bin/bash
set -o errexit
set -o nounset
set -o pipefail

env_file="${SHARED_DIR}/aro-hcp-slot.env"
if [[ -f "${env_file}" ]]; then
    # shellcheck disable=SC1090
    source "${env_file}"
fi

export LOCATION="${SELECTED_LOCATION:-${LOCATION:-}}"
: "${LOCATION:?LOCATION must be provided by SELECTED_LOCATION or the legacy runtime slot export file}"

export CLUSTER_PROFILE_DIR="/var/run/aro-hcp-${VAULT_SECRET_PROFILE}"

export AZURE_CLIENT_ID; AZURE_CLIENT_ID=$(cat "${CLUSTER_PROFILE_DIR}/client-id")
export AZURE_TENANT_ID; AZURE_TENANT_ID=$(cat "${CLUSTER_PROFILE_DIR}/tenant")
export AZURE_CLIENT_SECRET; AZURE_CLIENT_SECRET=$(cat "${CLUSTER_PROFILE_DIR}/client-secret")
INFRA_SUBSCRIPTION_ID=$(cat "${CLUSTER_PROFILE_DIR}/infra-${ARO_HCP_DEPLOY_ENV}-subscription-id")
export INFRA_SUBSCRIPTION_ID
export DEPLOY_ENV="${ARO_HCP_DEPLOY_ENV}"
export AZURE_TOKEN_CREDENTIALS=prod

az login --service-principal -u "${AZURE_CLIENT_ID}" -p "${AZURE_CLIENT_SECRET}" --tenant "${AZURE_TENANT_ID}" --output none
az account set --subscription "${INFRA_SUBSCRIPTION_ID}"
oc version
kubelogin --version

# Check out main branch to provision the baseline environment.
# The container image has the PR source baked in; we swap to main so that
# Bicep templates, Helm charts, config, and pipeline definitions all come
# from the current state of the default branch.
echo "Fetching and checking out main for baseline provision ..."
git fetch https://github.com/Azure/ARO-HCP.git main
git checkout -f FETCH_HEAD
echo "Checked out main at $(git rev-parse --short HEAD)"

# The CSPR postsubmit pushes service images to ACR tagged with the 7-char
# commit SHA (see aro-hcp-images-push step). Resolve the tag and look up
# the digest for each service image so the baseline uses main's actual images.
MAIN_SHA=$(git rev-parse --short=7 HEAD)

CONFIG_FILE="config/rendered/dev/${DEPLOY_ENV}/westus3.yaml"
if [[ ! -f "${CONFIG_FILE}" ]]; then
  CONFIG_FILE="config/rendered/dev/${DEPLOY_ENV}/centralus.yaml"
fi
if [[ ! -f "${CONFIG_FILE}" ]]; then
  echo "ERROR: No rendered config found for ${DEPLOY_ENV} (tried westus3.yaml, centralus.yaml)"
  exit 1
fi

ACR_NAME=$(yq '.acr.svc.name' "${CONFIG_FILE}")
ACR_URL="${ACR_NAME}.azurecr.io"

BACKEND_REPO=$(yq '.backend.image.repository' "${CONFIG_FILE}")
FRONTEND_REPO=$(yq '.frontend.image.repository' "${CONFIG_FILE}")
ADMIN_API_REPO=$(yq '.adminApi.image.repository' "${CONFIG_FILE}")
SESSIONGATE_REPO=$(yq '.sessiongate.image.repository' "${CONFIG_FILE}")
FLEET_REPO=$(yq '.fleet.image.repository' "${CONFIG_FILE}")
MGMT_AGENT_REPO=$(yq '.mgmtAgent.image.repository' "${CONFIG_FILE}")
KUBE_APPLIER_REPO=$(yq '.kubeApplier.image.repository' "${CONFIG_FILE}")
# hcpRecovery is not pushed to ACR by images-push; its config digest is
# empty by default, so we leave it as-is rather than trying to resolve it.

echo "ACR: ${ACR_URL}, main SHA: ${MAIN_SHA}"
echo "Repos: backend=${BACKEND_REPO} frontend=${FRONTEND_REPO} admin-api=${ADMIN_API_REPO} sessiongate=${SESSIONGATE_REPO} fleet=${FLEET_REPO} mgmt-agent=${MGMT_AGENT_REPO} kube-applier=${KUBE_APPLIER_REPO}"

# Wait for the postsubmit images-push job to have pushed images for this
# commit. Check one representative repo (fleet); all are pushed together.
MAX_ATTEMPTS=30
POLL_INTERVAL=30
echo "Polling ACR for ${FLEET_REPO}:${MAIN_SHA} (up to $((MAX_ATTEMPTS * POLL_INTERVAL))s) ..."
for attempt in $(seq 1 ${MAX_ATTEMPTS}); do
  if az acr manifest show -r "${ACR_NAME}" -n "${FLEET_REPO}:${MAIN_SHA}" &>/dev/null; then
    echo "Images for ${MAIN_SHA} available after attempt ${attempt}"
    break
  fi
  if [[ ${attempt} -eq ${MAX_ATTEMPTS} ]]; then
    echo "ERROR: Images for ${MAIN_SHA} not found in ${ACR_NAME} after ${MAX_ATTEMPTS} attempts."
    echo "Falling back to parent commit ..."
    MAIN_SHA=$(git rev-parse --short=7 HEAD~1)
    echo "Trying parent commit: ${MAIN_SHA}"
    if ! az acr manifest show -r "${ACR_NAME}" -n "${FLEET_REPO}:${MAIN_SHA}" &>/dev/null; then
      echo "ERROR: Images for fallback ${MAIN_SHA} also not found. Aborting."
      exit 1
    fi
    echo "Fallback images found for ${MAIN_SHA}"
    break
  else
    echo "Attempt ${attempt}/${MAX_ATTEMPTS}: not yet available, retrying in ${POLL_INTERVAL}s ..."
    sleep ${POLL_INTERVAL}
  fi
done

# Resolve each image tag to its digest from ACR.
resolve_digest() {
  local repo=$1 tag=$2
  local digest
  digest=$(az acr manifest show-metadata -r "${ACR_NAME}" -n "${repo}:${tag}" --query 'digest' -o tsv)
  if [[ -z "${digest}" ]]; then
    echo "ERROR: Failed to resolve digest for ${repo}:${tag}" >&2
    return 1
  fi
  echo "${digest}"
}

echo "Resolving image digests for tag ${MAIN_SHA} ..."
BACKEND_DIGEST=$(resolve_digest "${BACKEND_REPO}" "${MAIN_SHA}")
FRONTEND_DIGEST=$(resolve_digest "${FRONTEND_REPO}" "${MAIN_SHA}")
ADMIN_API_DIGEST=$(resolve_digest "${ADMIN_API_REPO}" "${MAIN_SHA}")
SESSIONGATE_DIGEST=$(resolve_digest "${SESSIONGATE_REPO}" "${MAIN_SHA}")
FLEET_DIGEST=$(resolve_digest "${FLEET_REPO}" "${MAIN_SHA}")
MGMT_AGENT_DIGEST=$(resolve_digest "${MGMT_AGENT_REPO}" "${MAIN_SHA}")
KUBE_APPLIER_DIGEST=$(resolve_digest "${KUBE_APPLIER_REPO}" "${MAIN_SHA}")

echo "Resolved digests:"
echo "  backend:      ${BACKEND_DIGEST}"
echo "  frontend:     ${FRONTEND_DIGEST}"
echo "  admin-api:    ${ADMIN_API_DIGEST}"
echo "  sessiongate:  ${SESSIONGATE_DIGEST}"
echo "  fleet:        ${FLEET_DIGEST}"
echo "  mgmt-agent:   ${MGMT_AGENT_DIGEST}"
echo "  kube-applier: ${KUBE_APPLIER_DIGEST}"

OVERRIDE_CONFIG_FILE="${SHARED_DIR}/config-override.yaml"

# Image overrides — point at ACR images built from main's commit.
yq eval -n "
  .clouds.dev.environments.${DEPLOY_ENV}.defaults.backend.image.registry = \"${ACR_URL}\" |
  .clouds.dev.environments.${DEPLOY_ENV}.defaults.backend.image.repository = \"${BACKEND_REPO}\" |
  .clouds.dev.environments.${DEPLOY_ENV}.defaults.backend.image.digest = \"${BACKEND_DIGEST}\" |
  .clouds.dev.environments.${DEPLOY_ENV}.defaults.frontend.image.registry = \"${ACR_URL}\" |
  .clouds.dev.environments.${DEPLOY_ENV}.defaults.frontend.image.repository = \"${FRONTEND_REPO}\" |
  .clouds.dev.environments.${DEPLOY_ENV}.defaults.frontend.image.digest = \"${FRONTEND_DIGEST}\" |
  .clouds.dev.environments.${DEPLOY_ENV}.defaults.adminApi.image.registry = \"${ACR_URL}\" |
  .clouds.dev.environments.${DEPLOY_ENV}.defaults.adminApi.image.repository = \"${ADMIN_API_REPO}\" |
  .clouds.dev.environments.${DEPLOY_ENV}.defaults.adminApi.image.digest = \"${ADMIN_API_DIGEST}\" |
  .clouds.dev.environments.${DEPLOY_ENV}.defaults.sessiongate.image.registry = \"${ACR_URL}\" |
  .clouds.dev.environments.${DEPLOY_ENV}.defaults.sessiongate.image.repository = \"${SESSIONGATE_REPO}\" |
  .clouds.dev.environments.${DEPLOY_ENV}.defaults.sessiongate.image.digest = \"${SESSIONGATE_DIGEST}\" |
  .clouds.dev.environments.${DEPLOY_ENV}.defaults.fleet.image.registry = \"${ACR_URL}\" |
  .clouds.dev.environments.${DEPLOY_ENV}.defaults.fleet.image.repository = \"${FLEET_REPO}\" |
  .clouds.dev.environments.${DEPLOY_ENV}.defaults.fleet.image.digest = \"${FLEET_DIGEST}\" |
  .clouds.dev.environments.${DEPLOY_ENV}.defaults.mgmtAgent.image.registry = \"${ACR_URL}\" |
  .clouds.dev.environments.${DEPLOY_ENV}.defaults.mgmtAgent.image.repository = \"${MGMT_AGENT_REPO}\" |
  .clouds.dev.environments.${DEPLOY_ENV}.defaults.mgmtAgent.image.digest = \"${MGMT_AGENT_DIGEST}\" |
  .clouds.dev.environments.${DEPLOY_ENV}.defaults.kubeApplier.image.registry = \"${ACR_URL}\" |
  .clouds.dev.environments.${DEPLOY_ENV}.defaults.kubeApplier.image.repository = \"${KUBE_APPLIER_REPO}\" |
  .clouds.dev.environments.${DEPLOY_ENV}.defaults.kubeApplier.image.digest = \"${KUBE_APPLIER_DIGEST}\"
" > "${OVERRIDE_CONFIG_FILE}"

# MSI mock SP overrides (if provided) — needed for both baseline and upgrade
if [[ -n "${LEASED_MSI_MOCK_SP:-}" ]]; then
  MSI_MOCK_CLIENT_ID=$(yq ".miMockPool.\"${LEASED_MSI_MOCK_SP}\".clientId" dev-infrastructure/openshift-ci/msi-mock-pool.yaml)
  MSI_MOCK_PRINCIPAL_ID=$(yq ".miMockPool.\"${LEASED_MSI_MOCK_SP}\".principalId" dev-infrastructure/openshift-ci/msi-mock-pool.yaml)
  MSI_MOCK_CERT_NAME=$(yq ".miMockPool.\"${LEASED_MSI_MOCK_SP}\".certName" dev-infrastructure/openshift-ci/msi-mock-pool.yaml)
  if [[ -z "${MSI_MOCK_CLIENT_ID}" || "${MSI_MOCK_CLIENT_ID}" == "null" || \
        -z "${MSI_MOCK_PRINCIPAL_ID}" || "${MSI_MOCK_PRINCIPAL_ID}" == "null" || \
        -z "${MSI_MOCK_CERT_NAME}" || "${MSI_MOCK_CERT_NAME}" == "null" ]]; then
    echo "ERROR: LEASED_MSI_MOCK_SP='${LEASED_MSI_MOCK_SP}' not found in dev-infrastructure/openshift-ci/msi-mock-pool.yaml"
    exit 1
  fi
  echo "MSI mock SP override: ${LEASED_MSI_MOCK_SP} -> clientId=${MSI_MOCK_CLIENT_ID}"
  yq -i "
    .clouds.dev.environments.${DEPLOY_ENV}.defaults.miMockClientId = \"${MSI_MOCK_CLIENT_ID}\" |
    .clouds.dev.environments.${DEPLOY_ENV}.defaults.miMockPrincipalId = \"${MSI_MOCK_PRINCIPAL_ID}\" |
    .clouds.dev.environments.${DEPLOY_ENV}.defaults.miMockCertName = \"${MSI_MOCK_CERT_NAME}\"
  " "${OVERRIDE_CONFIG_FILE}"
else
  echo "No MSI mock SP lease provided, skipping mock SP overrides"
fi

# Temporary MGMT cluster sizing overrides for single-wave E2E parallelism.
# These will be removed once the matching config.yaml defaults land in ARO-HCP.
# When identity containers are leased (E2E runs), scale up the node pool.
# Otherwise, explicitly set minCount=1 to match the current ci config default
# and ensure non-leased runs (e.g. healthcheck) use minimal sizing.
if [[ -n "${LEASED_MSI_CONTAINERS:-}" ]]; then
  yq -i "
    .clouds.dev.environments.${DEPLOY_ENV}.defaults.mgmt.aks.userAgentPool.minCount = 7 |
    .clouds.dev.environments.${DEPLOY_ENV}.defaults.mgmt.aks.infraAgentPool.vmSize = \"Standard_D8ds_v6\"
  " "${OVERRIDE_CONFIG_FILE}"
else
  yq -i "
    .clouds.dev.environments.${DEPLOY_ENV}.defaults.mgmt.aks.userAgentPool.minCount = 1
  " "${OVERRIDE_CONFIG_FILE}"
fi

echo "Created override config at: ${OVERRIDE_CONFIG_FILE}"
cat "${OVERRIDE_CONFIG_FILE}"

CONFIG_PROV="${SHARED_DIR}/config-prov.yaml"

finalize() {
    if [[ -s "${CONFIG_PROV}" ]]; then
        mv "${CONFIG_PROV}" "${SHARED_DIR}/config.yaml"
        cp "${SHARED_DIR}/config.yaml" "${ARTIFACT_DIR}/config.yaml"
    fi
}
trap finalize EXIT

unset GOFLAGS

EXTRA_ARGS="--region ${LOCATION}"
if [[ "${ARO_HCP_PROVISION_ABORT_IF_EXISTS:-true}" == "true" ]]; then
  EXTRA_ARGS+=" --abort-if-regional-exist"
fi

make -o tooling/templatize/templatize entrypoint/Region \
  DEPLOY_ENV="${DEPLOY_ENV}" \
  OVERRIDE_CONFIG_FILE="${OVERRIDE_CONFIG_FILE}" \
  EXTRA_ARGS="${EXTRA_ARGS}" \
  TIMING_OUTPUT=${SHARED_DIR}/steps.yaml.gz \
  ENTRYPOINT_JUNIT_OUTPUT=${ARTIFACT_DIR}/junit_entrypoint_baseline.xml \
  CONFIG_OUTPUT=${CONFIG_PROV}

touch "${SHARED_DIR}/provision-from-main-complete"
echo "Baseline provision from main complete."
