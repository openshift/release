#!/bin/bash
set -euo pipefail

export CLUSTER_PROFILE_DIR="/var/run/aro-hcp-${VAULT_SECRET_PROFILE}"

# Do not enable tracing (set -x) around the credential reads and az login below:
# tracing would expand the `az login -p <secret>` line and echo the
# client-secret into CI logs. This script runs without `set -x` for this reason.
export AZURE_CLIENT_ID; AZURE_CLIENT_ID=$(cat "${CLUSTER_PROFILE_DIR}/client-id")
export AZURE_TENANT_ID; AZURE_TENANT_ID=$(cat "${CLUSTER_PROFILE_DIR}/tenant")
export AZURE_CLIENT_SECRET; AZURE_CLIENT_SECRET=$(cat "${CLUSTER_PROFILE_DIR}/client-secret")

az login --service-principal -u "${AZURE_CLIENT_ID}" -p "${AZURE_CLIENT_SECRET}" --tenant "${AZURE_TENANT_ID}" --output none

# Resolves a single dotted config key (for example "monitoring.grafanaName")
# from the templatize inspect output for the selected deploy environment and region.
# Argument 1: the dotted config key to resolve.
resolve_config_from_templatize() {
    local config_ref="$1"
    local resolved_value

    resolved_value="$(
        "tooling/templatize/templatize-$(uname -m)" inspect \
        --config-file "config/config.yaml" \
        --dev-settings-file "tooling/templatize/settings.yaml" \
        --dev-environment "${DEPLOY_ENV}" \
        --region "${LOCATION}" \
        --format yaml | yq eval -r ".${config_ref} // \"\"" -
    )"

    if [[ -z "${resolved_value}" ]]; then
        echo "ERROR: Could not resolve ${config_ref} from templatize inspect output" >&2
        exit 1
    fi

    printf '%s\n' "${resolved_value}"
}

# Resolves an Azure subscription ID from its display name.
# Argument 1: the subscription display name to resolve.
resolve_subscription_id_from_name() {
    local subscription_name="$1"
    local subscription_id

    subscription_id="$(
        az account list --output json \
        | jq -r --arg name "${subscription_name}" 'map(select(.name == $name) | .id) | first // ""'
    )"

    if [[ -z "${subscription_id}" ]]; then
        echo "ERROR: Could not resolve subscription ID for '${subscription_name}'" >&2
        exit 1
    fi

    printf '%s\n' "${subscription_id}"
}

export GRAFANA_NAME; GRAFANA_NAME="$(resolve_config_from_templatize "monitoring.grafanaName")"
export GRAFANA_RESOURCE_GROUP; GRAFANA_RESOURCE_GROUP="$(resolve_config_from_templatize "global.rg")"

SUBSCRIPTION_KEY="$(resolve_config_from_templatize "global.subscription.key")"
SUBSCRIPTION_ID="$(resolve_subscription_id_from_name "${SUBSCRIPTION_KEY}")"
az account set --subscription "${SUBSCRIPTION_ID}"

# Consume the GitHub token minted by the aro-hcp-github-app-auth step.
if [[ -s "${SHARED_DIR}/github-token" ]]; then
    export GITHUB_TOKEN; GITHUB_TOKEN=$(cat "${SHARED_DIR}/github-token")
else
    echo "WARNING: no GitHub token found in \${SHARED_DIR}. PR comment will be skipped." >&2
fi

bash hack/ci/grafana-preview.sh
