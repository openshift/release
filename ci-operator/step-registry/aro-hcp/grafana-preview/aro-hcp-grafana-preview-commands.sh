#!/bin/bash
set -euo pipefail

export GITHUB_REPO_OWNER="${GITHUB_REPO_OWNER:-Azure}"
export GITHUB_REPO_NAME="${GITHUB_REPO_NAME:-ARO-HCP}"

export CLUSTER_PROFILE_DIR="/var/run/aro-hcp-${VAULT_SECRET_PROFILE}"

# Do not enable tracing (set -x) around the credential reads and az login below:
# tracing would expand the `az login -p <secret>` line and echo the
# client-secret into CI logs. This script runs without `set -x` for this reason.
export AZURE_CLIENT_ID; AZURE_CLIENT_ID=$(cat "${CLUSTER_PROFILE_DIR}/client-id")
export AZURE_TENANT_ID; AZURE_TENANT_ID=$(cat "${CLUSTER_PROFILE_DIR}/tenant")
export AZURE_CLIENT_SECRET; AZURE_CLIENT_SECRET=$(cat "${CLUSTER_PROFILE_DIR}/client-secret")
export GLOBAL_INFRA_SUBSCRIPTION_ID; GLOBAL_INFRA_SUBSCRIPTION_ID=$(cat "${CLUSTER_PROFILE_DIR}/infra-global-subscription-id")

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

export GRAFANA_NAME; GRAFANA_NAME="$(resolve_config_from_templatize "monitoring.grafanaName")"
export GRAFANA_RESOURCE_GROUP; GRAFANA_RESOURCE_GROUP="$(resolve_config_from_templatize "global.rg")"

az account set --subscription "${GLOBAL_INFRA_SUBSCRIPTION_ID}"

# Exit just before posting so that pj-rehearse can test everything above this line
if [[ -n "${REPO_OWNER:-}${REPO_NAME:-}" \
    && "${REPO_OWNER:-}/${REPO_NAME:-}" != "${GITHUB_REPO_OWNER}/${GITHUB_REPO_NAME}" ]]; then
    echo "This job runs for ${REPO_OWNER:-}/${REPO_NAME:-}, not ${GITHUB_REPO_OWNER}/${GITHUB_REPO_NAME}. Resolved the Grafana config, but dashboard preview will be skipped."
    exit 0
fi

# Consume the GitHub token minted by the aro-hcp-github-app-auth step.
if [[ ! -s "${SHARED_DIR}/github-token" ]]; then
    echo "ERROR: no GitHub token found in \${SHARED_DIR}; the PR comment with the preview links cannot be posted." >&2
    exit 1
fi
export GITHUB_TOKEN; GITHUB_TOKEN=$(cat "${SHARED_DIR}/github-token")

bash hack/ci/grafana-preview.sh
