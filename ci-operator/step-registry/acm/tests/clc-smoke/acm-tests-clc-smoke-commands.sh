#!/bin/bash
set -euxo pipefail; shopt -s inherit_errexit

typeset secretsDir="/tmp/secrets"
typeset optionFile="./options.yaml"
typeset awsCredFile="${CLUSTER_PROFILE_DIR}/.awscred"

if [[ "${SKIP_OCP_DEPLOY:-false}" == "true" ]]; then
    cp "${secretsDir}/ci/kubeconfig" "${SHARED_DIR}/kubeconfig"
    cp "${secretsDir}/ci/kubeadmin-password" "${SHARED_DIR}/kubeadmin-password"
fi

cp "${secretsDir}/clc-interop/secret-options-yaml" "${optionFile}"

if [[ -f "${awsCredFile}" ]]; then
    typeset awsAccKeyID=
    typeset awsAccKeyToken=

    # tracing off: AWS credentials
    set +x
    awsAccKeyID="$(sed -nE 's/^\s*aws_access_key_id\s*=\s*//p;T;q' "${awsCredFile}")"
    awsAccKeyToken="$(sed -nE 's/^\s*aws_secret_access_key\s*=\s*//p;T;q' "${awsCredFile}")"

    if [[ -z "${awsAccKeyID}" ]] || [[ -z "${awsAccKeyToken}" ]]; then
        echo "ERROR: Failed to extract AWS credentials from ${awsCredFile}" 1>&2
        exit 1
    fi

    yq -o json eval . "${optionFile}" |
    jq -c \
          --arg awsAccKeyID "${awsAccKeyID}" \
          --rawfile awsAccKeyToken <(printf '%s' "${awsAccKeyToken}") \
        '
          .options.connections.apiKeys.aws|=(
                .awsAccessKeyID=$awsAccKeyID |
                .awsSecretAccessKeyID=($awsAccKeyToken | rtrimstr("\n"))
            )
        ' |
    yq -p json -o yaml eval . > "${optionFile}.tmp"
    mv -f "${optionFile}.tmp" "${optionFile}"
    set -x

    unset awsAccKeyID awsAccKeyToken
fi

# tracing off: kubeadmin password
set +x
export CYPRESS_OPTIONS_HUB_PASSWORD=
CYPRESS_OPTIONS_HUB_PASSWORD="$(cat "${SHARED_DIR}/kubeadmin-password")"

typeset cypress_base_url cypress_hub_api_url cypress_ocp_version cloud_providers
cypress_base_url="$(oc whoami --show-console)"
cypress_hub_api_url="$(oc whoami --show-server)"
cypress_ocp_version="$(cat "${secretsDir}/clc/ocp_image_version")"
cloud_providers="$(cat "${secretsDir}/clc/ocp_cloud_providers")"

if [[ -z "${cypress_base_url}" ]] || [[ -z "${cypress_hub_api_url}" ]]; then
    echo "ERROR: Console URL or API URL is empty; oc whoami returned no usable value" 1>&2
    exit 1
fi

typeset clcStatus=0

CYPRESS_BASE_URL="${cypress_base_url}" \
CYPRESS_HUB_API_URL="${cypress_hub_api_url}" \
CYPRESS_CLC_OCP_IMAGE_VERSION="${cypress_ocp_version}" \
CLOUD_PROVIDERS="${cloud_providers}" \
bash +x ./execute_clc_interop_commands.sh || clcStatus=$?
set -x

unset CYPRESS_OPTIONS_HUB_PASSWORD

typeset reportStatus=0
cp -r reports "${ARTIFACT_DIR}/" || reportStatus=$?
if (( clcStatus != 0 )); then
    exit "${clcStatus}"
fi
exit "${reportStatus}"
