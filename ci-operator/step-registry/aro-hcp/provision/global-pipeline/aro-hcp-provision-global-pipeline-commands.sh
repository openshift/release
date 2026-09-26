#!/bin/bash
set -o errexit
set -o nounset
set -o pipefail

export CLUSTER_PROFILE_DIR="/var/run/aro-hcp-${VAULT_SECRET_PROFILE}"

export AZURE_CLIENT_ID; AZURE_CLIENT_ID=$(cat "${CLUSTER_PROFILE_DIR}/client-id")
export AZURE_TENANT_ID; AZURE_TENANT_ID=$(cat "${CLUSTER_PROFILE_DIR}/tenant")
export AZURE_CLIENT_SECRET; AZURE_CLIENT_SECRET=$(cat "${CLUSTER_PROFILE_DIR}/client-secret")
export GLOBAL_SUBSCRIPTION_ID; GLOBAL_SUBSCRIPTION_ID=$(cat "${CLUSTER_PROFILE_DIR}/infra-global-subscription-id")
export GLOBAL_SUBSCRIPTION_NAME; GLOBAL_SUBSCRIPTION_NAME=$(cat "${CLUSTER_PROFILE_DIR}/infra-global-subscription-name")
export KUSTO_LOCATION; KUSTO_LOCATION="${KUSTO_LOCATION:-eastus2}"
export DEPLOY_ENV="ci00"

resolve_config_from_templatize() {
    local config_ref="$1"
    local region="$2"
    local resolved_value
    local -a override_args=()

    if [[ -n "${OVERRIDE_CONFIG_FILE:-}" ]]; then
        override_args=(--config-file-override "${OVERRIDE_CONFIG_FILE}")
    fi

    resolved_value="$(
        "tooling/templatize/templatize-$(uname -m)" inspect \
        --config-file "config/config.yaml" \
        "${override_args[@]}" \
        --dev-settings-file "tooling/templatize/settings.yaml" \
        --dev-environment "${DEPLOY_ENV}" \
        --region "${region}" \
        --format yaml | yq eval -r ".${config_ref} // \"\"" -
    )"

    if [[ -z "${resolved_value}" ]]; then
        echo "ERROR: Could not resolve ${config_ref} from templatize inspect output"
        exit 1
    fi

    printf '%s\n' "${resolved_value}"
}

az login --service-principal -u "${AZURE_CLIENT_ID}" -p "${AZURE_CLIENT_SECRET}" --tenant "${AZURE_TENANT_ID}" --output none
unset GOFLAGS

#-# GLOBAL PIPELINE #-#

# Keep shared/global infra updates in this job so they run under the same
# Boskos lease and cannot race with each other.
# Run global first so post-global shared dependencies exist before add-ons.
make -o tooling/templatize/templatize pipeline/Global DEPLOY_ENV="${DEPLOY_ENV}" STEP_CACHE_DIR= EXTRA_ARGS="--region ${LOCATION}"

#-# DEV ACR CUSTOMIZATIONS #-#

# Apply DEV ACR customizations after global infra has converged.
GLOBAL_RESOURCE_GROUP="$(resolve_config_from_templatize "global.rg" "${LOCATION}")"
GLOBAL_SUBSCRIPTION_KEY="$(resolve_config_from_templatize "global.subscription.key" "${LOCATION}")"
if [[ "${GLOBAL_SUBSCRIPTION_KEY}" != "${GLOBAL_SUBSCRIPTION_NAME}" ]]; then
    echo "ERROR: Config global subscription ${GLOBAL_SUBSCRIPTION_KEY} does not match cluster profile ${GLOBAL_SUBSCRIPTION_NAME}"
    exit 1
fi

# Keep generated bicepparam under dev-infrastructure/configurations so the
# relative "using '../templates/dev-acr.bicep'" path resolves correctly.
ACR_PARAMETERS_FILE="${ACR_PARAMETERS_FILE:-dev-infrastructure/configurations/acr-svc-ci-$(date +%s).bicepparam}"
"tooling/templatize/templatize-$(uname -m)" generate \
    --config-file "config/config.yaml" \
    --dev-settings-file "tooling/templatize/settings.yaml" \
    --dev-environment "${DEPLOY_ENV}" \
    --region "${LOCATION}" \
    --input "dev-infrastructure/configurations/acr-svc.tmpl.bicepparam" \
    --output "${ACR_PARAMETERS_FILE}"

az deployment group create \
    --subscription "${GLOBAL_SUBSCRIPTION_ID}" \
    --name "global-acr-svc" \
    --resource-group "${GLOBAL_RESOURCE_GROUP}" \
    --template-file "dev-infrastructure/templates/dev-acr.bicep" \
    --parameters "${ACR_PARAMETERS_FILE}" \
    --only-show-errors

#-# GEOGRAPHY PIPELINE (KUSTO) #-#

# Kusto now lives in the Geography pipeline. Management is disabled by default
# for most dev environments (including ci00), so this job explicitly overrides
# kusto.manageInstance to true and runs Geography as the single kusto manager.

# Global postsubmit is the only owner of Kusto management. Override ci00 defaults
# at runtime so Geography does real management work in this job.
OVERRIDE_CONFIG_FILE="${OVERRIDE_CONFIG_FILE:-/tmp/global-override-config-$(date +%s).yaml}"
yq eval -n "
  .clouds.dev.environments.${DEPLOY_ENV}.defaults.kusto.manageInstance = true
" > "${OVERRIDE_CONFIG_FILE}"
echo "Created override config at: ${OVERRIDE_CONFIG_FILE}"
cat "${OVERRIDE_CONFIG_FILE}"

make -o tooling/templatize/templatize pipeline/Geography DEPLOY_ENV="${DEPLOY_ENV}" OVERRIDE_CONFIG_FILE="${OVERRIDE_CONFIG_FILE}" STEP_CACHE_DIR= EXTRA_ARGS="--region ${KUSTO_LOCATION}"

# Ensure kusto persist tag is set
KUSTO_RESOURCE_GROUP="$(resolve_config_from_templatize "kusto.rg" "${KUSTO_LOCATION}")"
az tag create \
    --resource-id "$(az group show --subscription "${GLOBAL_SUBSCRIPTION_ID}" --resource-group "${KUSTO_RESOURCE_GROUP}" --query id -o tsv)" \
    --tags persist=true \
    --only-show-errors
