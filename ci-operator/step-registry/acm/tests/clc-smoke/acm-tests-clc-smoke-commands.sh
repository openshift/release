#!/bin/bash
set -euxo pipefail; shopt -s inherit_errexit

# shellcheck disable=SC2317
_propagate_junit () {
    mkdir -p "${SHARED_DIR}/junit"
    find "${ARTIFACT_DIR}" -name '*.xml' -exec cp {} "${SHARED_DIR}/junit/" \; 2>/dev/null || true
}
trap _propagate_junit EXIT

typeset secretsDir="/tmp/secrets"
typeset optionFile="./options.yaml"
typeset awsCredFile="${CLUSTER_PROFILE_DIR}/.awscred"

if [[ "${SKIP_OCP_DEPLOY:-false}" == "true" ]]; then
    cp "${secretsDir}/ci/kubeconfig" "${SHARED_DIR}/kubeconfig"
    cp "${secretsDir}/ci/kubeadmin-password" "${SHARED_DIR}/kubeadmin-password"
fi

cp "${secretsDir}/clc-interop/secret-options-yaml" "${optionFile}"

if [[ -f "${awsCredFile}" ]]; then
    typeset awsAccKeyID=''
    typeset awsAccKeyToken=''

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

typeset cypressBaseUrl=''
cypressBaseUrl="$(oc whoami --show-console)"
typeset cypressHubApiUrl=''
cypressHubApiUrl="$(oc whoami --show-server)"
typeset cypressOcpVersion=''
cypressOcpVersion="$(cat "${secretsDir}/clc/ocp_image_version")"
typeset cloudProviders=''
cloudProviders="$(cat "${secretsDir}/clc/ocp_cloud_providers")"

if [[ -z "${cypressBaseUrl}" ]] || [[ -z "${cypressHubApiUrl}" ]]; then
    echo "ERROR: Console URL or API URL is empty; oc whoami returned no usable value" 1>&2
    exit 1
fi

typeset clcStatus=0

CYPRESS_BASE_URL="${cypressBaseUrl}" \
CYPRESS_HUB_API_URL="${cypressHubApiUrl}" \
CYPRESS_CLC_OCP_IMAGE_VERSION="${cypressOcpVersion}" \
CLOUD_PROVIDERS="${cloudProviders}" \
bash +x ./execute_clc_interop_commands.sh || clcStatus=$?
set -x

unset CYPRESS_OPTIONS_HUB_PASSWORD

typeset reportStatus=0
cp -r reports "${ARTIFACT_DIR}/" || reportStatus=$?
if (( clcStatus != 0 )); then
    exit "${clcStatus}"
fi
exit "${reportStatus}"
