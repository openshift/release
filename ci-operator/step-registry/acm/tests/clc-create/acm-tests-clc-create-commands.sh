#!/bin/bash
set -euxo pipefail; shopt -s inherit_errexit

# --- Variables ---
typeset secretsDir="/tmp/secrets"
typeset optionFile="./options.yaml"
typeset awsCredFile="${CLUSTER_PROFILE_DIR}/.awscred"

# Get the creds from ACMQE CI vault and run the automation on pre-existing HUB
if [[ "${SKIP_OCP_DEPLOY:-false}" == "true" ]]; then
    : "------------ Skipping OCP Deploy = ${SKIP_OCP_DEPLOY} ------------"
    cp "${secretsDir}/ci/kubeconfig" "${SHARED_DIR}/kubeconfig"
    cp "${secretsDir}/ci/kubeadmin-password" "${SHARED_DIR}/kubeadmin-password"
fi

cp "${secretsDir}/clc-interop/secret-options-yaml" "${optionFile}"

# Update the AWS credentials in options.yaml from cluster profile
if [[ -f "${awsCredFile}" ]]; then
    typeset awsAccKeyID=
    typeset awsAccKeyToken=

    set +x
    awsAccKeyID="$(sed -nE 's/^\s*aws_access_key_id\s*=\s*//p;T;q' "${awsCredFile}")"
    awsAccKeyToken="$(sed -nE 's/^\s*aws_secret_access_key\s*=\s*//p;T;q' "${awsCredFile}")"

    [ -n "${awsAccKeyID}" ] && [ -n "${awsAccKeyToken}" ]

    : "Updating credentials in ${optionFile}..."
    yq -o json eval . "${optionFile}" |
    jq -c \
          --arg awsAccKeyID "${awsAccKeyID}" \
          --arg awsAccKeyToken "${awsAccKeyToken}" \
        '
          .connections.apiKeys.aws|=(
                .awsAccessKeyID=$awsAccKeyID |
                .awsSecretAccessKey=$awsAccKeyToken
            )
        ' |
    yq -p json -o yaml eval . > "${optionFile}.tmp"
    mv -f "${optionFile}.tmp" "${optionFile}"
    set -x

    unset awsAccKeyID awsAccKeyToken
fi

: "Executing CLC interop commands..."
set +x
export CYPRESS_OPTIONS_HUB_PASSWORD=
CYPRESS_OPTIONS_HUB_PASSWORD="$(cat "${SHARED_DIR}/kubeadmin-password")"
set -x

CYPRESS_BASE_URL="$(oc whoami --show-console)" \
CYPRESS_HUB_API_URL="$(oc whoami --show-server)" \
CYPRESS_CLC_OCP_IMAGE_VERSION="$(cat "${secretsDir}/clc/ocp_image_version")" \
CLOUD_PROVIDERS="$(cat "${secretsDir}/clc/ocp_cloud_providers")" \
bash +x ./execute_clc_interop_commands.sh || :

unset CYPRESS_OPTIONS_HUB_PASSWORD

: "Copying artifacts..."
cp -r reports "${ARTIFACT_DIR}/"

true
