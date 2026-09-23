#!/bin/bash

set -o nounset
set -o errexit
set -o pipefail

trap 'CHILDREN=$(jobs -p); if test -n "${CHILDREN}"; then kill ${CHILDREN} && wait; fi' TERM

CLUSTER_ID=$(cat "${SHARED_DIR}/cluster-id")

function set_proxy () {
    if test -s "${SHARED_DIR}/proxy-conf.sh" ; then
        echo "setting the proxy"
        # cat "${SHARED_DIR}/proxy-conf.sh"
        echo "source ${SHARED_DIR}/proxy-conf.sh"
        source "${SHARED_DIR}/proxy-conf.sh"
    else
        echo "no proxy setting."
    fi
}

# Configure aws
CLOUD_PROVIDER_REGION=${LEASED_RESOURCE}
AWSCRED="${CLUSTER_PROFILE_DIR}/.awscred"
if [[ -f "${AWSCRED}" ]]; then
  export AWS_SHARED_CREDENTIALS_FILE="${AWSCRED}"
  export AWS_DEFAULT_REGION="${CLOUD_PROVIDER_REGION}"
else
  echo "Did not find compatible cloud provider cluster_profile"
  exit 1
fi

read_profile_file() {
  local file="${1}"
  if [[ -f "${CLUSTER_PROFILE_DIR}/${file}" ]]; then
    cat "${CLUSTER_PROFILE_DIR}/${file}"
  fi
}

# Log in
SSO_CLIENT_ID=$(read_profile_file "sso-client-id")
SSO_CLIENT_SECRET=$(read_profile_file "sso-client-secret")
ROSA_TOKEN=$(read_profile_file "ocm-token")
if [[ -n "${SSO_CLIENT_ID}" && -n "${SSO_CLIENT_SECRET}" ]]; then
  echo "Logging into ${OCM_LOGIN_ENV} with SSO credentials"
  rosa login --env "${OCM_LOGIN_ENV}" --client-id "${SSO_CLIENT_ID}" --client-secret "${SSO_CLIENT_SECRET}"
elif [[ -n "${ROSA_TOKEN}" ]]; then
  echo "Logging into ${OCM_LOGIN_ENV} with offline token"
  rosa login --env "${OCM_LOGIN_ENV}" --token "${ROSA_TOKEN}"
else
  echo "Cannot login! You need to securely supply SSO credentials or an ocm-token!"
  exit 1
fi


ISSUER_URL="$(</var/run/hypershift-ext-oidc-app-cli/issuer-url)"
CLI_CLIENT_ID="$(</var/run/hypershift-ext-oidc-app-cli/client-id)"
CONSOLE_CLIENT_ID="$(</var/run/hypershift-ext-oidc-app-console/client-id)"
CONSOLE_CLIENT_SECRET="$(</var/run/hypershift-ext-oidc-app-console/client-secret)"


HOSTED_CP=$(rosa describe cluster -c $CLUSTER_ID -o json | jq -r '.hypershift.enabled')
EXTERNAL_AUTH_CONFIG=$(rosa describe cluster -c $CLUSTER_ID -o json | jq -r '.external_auth_config.enabled')
# Conditionally append the CLI OIDC client part
if [[ "$EXTERNAL_AUTH_CONFIG" == "true" && "$HOSTED_CP" == "true" ]]; then
    echo "Create"
    rosa create external-auth-provider \
                --cluster=$CLUSTER_ID \
                --name="ocpe2e-auth" \
                --issuer-url=$ISSUER_URL \
                --issuer-audiences=$CLI_CLIENT_ID,$CONSOLE_CLIENT_ID \
                --claim-mapping-username-claim=email \
                --claim-mapping-groups-claim=groups \
                --console-client-id=$CONSOLE_CLIENT_ID \
                --console-client-secret=$CONSOLE_CLIENT_SECRET
    echo "successfully to create external auth provider....."
    echo "Wait some minutes to wait for kube-apiserver restart"
fi
