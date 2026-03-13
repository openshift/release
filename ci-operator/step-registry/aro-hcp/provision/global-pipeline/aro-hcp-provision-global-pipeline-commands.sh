#!/bin/bash
set -o errexit
set -o nounset
set -o pipefail

export AZURE_CLIENT_ID; AZURE_CLIENT_ID=$(cat "${CLUSTER_PROFILE_DIR}/client-id")
export AZURE_TENANT_ID; AZURE_TENANT_ID=$(cat "${CLUSTER_PROFILE_DIR}/tenant")
export AZURE_CLIENT_SECRET; AZURE_CLIENT_SECRET=$(cat "${CLUSTER_PROFILE_DIR}/client-secret")
export CUSTOMER_SUBSCRIPTION; CUSTOMER_SUBSCRIPTION=$(cat "${CLUSTER_PROFILE_DIR}/subscription-name")
export SUBSCRIPTION_ID; SUBSCRIPTION_ID=$(cat "${CLUSTER_PROFILE_DIR}/subscription-id")
export KUSTO_LOCATION; KUSTO_LOCATION="${KUSTO_LOCATION:-eastus2}"
export DEPLOY_ENV="prow"

resolve_config_from_templatize() {
    local config_ref="$1"
    local region="$2"
    local resolved_value
    local -a override_args=()

    if [[ -n "${OVERRIDE_CONFIG_FILE:-}" ]]; then
        override_args=(--config-file-override "${OVERRIDE_CONFIG_FILE}")
    fi

    resolved_value="$(
        tooling/templatize/templatize inspect \
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

resolve_subscription_id_from_name() {
    local subscription_name="$1"
    local subscription_id

    subscription_id="$(
        az account list --output json \
        | jq -r --arg name "${subscription_name}" 'map(select(.name == $name) | .id) | first // ""'
    )"

    if [[ -z "${subscription_id}" ]]; then
        echo "ERROR: Could not resolve subscription ID for '${subscription_name}'"
        exit 1
    fi

    printf '%s\n' "${subscription_id}"
}

az login --service-principal -u "${AZURE_CLIENT_ID}" -p "${AZURE_CLIENT_SECRET}" --tenant "${AZURE_TENANT_ID}" --output none
unset GOFLAGS

#-# GLOBAL PIPELINE #-#

# Keep shared/global infra updates in this job so they run under the same
# Boskos lease and cannot race with each other.
# Run global first so post-global shared dependencies exist before add-ons.
make -o tooling/templatize/templatize pipeline/Global DEPLOY_ENV="${DEPLOY_ENV}" EXTRA_ARGS="--region ${LOCATION} --step-cache-dir="

#-# DEV ACR CUSTOMIZATIONS #-#

# Apply DEV ACR customizations after global infra has converged.
GLOBAL_RESOURCE_GROUP="$(resolve_config_from_templatize "global.rg" "${LOCATION}")"
GLOBAL_SUBSCRIPTION_KEY="$(resolve_config_from_templatize "global.subscription.key" "${LOCATION}")"
GLOBAL_SUBSCRIPTION_ID="$(resolve_subscription_id_from_name "${GLOBAL_SUBSCRIPTION_KEY}")"

# Keep generated bicepparam under dev-infrastructure/configurations so the
# relative "using '../templates/dev-acr.bicep'" path resolves correctly.
ACR_PARAMETERS_FILE="${ACR_PARAMETERS_FILE:-dev-infrastructure/configurations/acr-svc-ci-$(date +%s).bicepparam}"
tooling/templatize/templatize generate \
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

#-# KUSTO PIPELINE #-#

# Run kusto pipeline for dev kusto instance. Kusto pipeline is part of the regional entrypoint, but management of kusto
# is disabled for all dev cloud environments. We override and set 'kusto.manageInstance = true' to make this job the sole
# manager of the dev kusto instance.

# Global postsubmit is the only owner of Kusto management. Override prow defaults
# at runtime so Log.Infra does real management work in this job.
OVERRIDE_CONFIG_FILE="${OVERRIDE_CONFIG_FILE:-/tmp/global-override-config-$(date +%s).yaml}"
yq eval -n "
  .clouds.dev.environments.${DEPLOY_ENV}.defaults.kusto.manageInstance = true
" > "${OVERRIDE_CONFIG_FILE}"
echo "Created override config at: ${OVERRIDE_CONFIG_FILE}"
cat "${OVERRIDE_CONFIG_FILE}"

make -o tooling/templatize/templatize pipeline/Log.Infra DEPLOY_ENV="${DEPLOY_ENV}" OVERRIDE_CONFIG_FILE="${OVERRIDE_CONFIG_FILE}" EXTRA_ARGS="--region ${KUSTO_LOCATION} --step-cache-dir="

# Ensure kusto persist tag is set
KUSTO_RESOURCE_GROUP="$(resolve_config_from_templatize "kusto.rg" "${KUSTO_LOCATION}")"
az tag create \
    --resource-id "$(az group show --subscription "${GLOBAL_SUBSCRIPTION_ID}" --resource-group "${KUSTO_RESOURCE_GROUP}" --query id -o tsv)" \
    --tags persist=true \
    --only-show-errors
