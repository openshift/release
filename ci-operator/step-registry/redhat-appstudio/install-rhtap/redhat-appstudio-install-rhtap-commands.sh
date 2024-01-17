#!/bin/bash

set -o nounset
set -o errexit
set -o pipefail

# Setup necessary env variables

export DEFAULT_QUAY_ORG DEFAULT_QUAY_ORG_TOKEN GITHUB_USER GITHUB_TOKEN QUAY_TOKEN QUAY_OAUTH_USER QUAY_OAUTH_TOKEN QUAY_OAUTH_TOKEN_RELEASE_SOURCE QUAY_OAUTH_TOKEN_RELEASE_DESTINATION OPENSHIFT_API OPENSHIFT_USERNAME OPENSHIFT_PASSWORD \
    GITHUB_ACCOUNTS_ARRAY PREVIOUS_RATE_REMAINING GITHUB_USERNAME_ARRAY GH_RATE_REMAINING GITHUB_TOKENS_LIST

DEFAULT_QUAY_ORG=redhat-appstudio-qe
DEFAULT_QUAY_ORG_TOKEN=$(cat /usr/local/ci-secrets/redhat-appstudio-qe/default-quay-org-token)
GITHUB_USER=""
GITHUB_TOKEN=""
QUAY_TOKEN=$(cat /usr/local/ci-secrets/redhat-appstudio-qe/quay-token)
QUAY_OAUTH_USER=$(cat /usr/local/ci-secrets/redhat-appstudio-qe/quay-oauth-user)
QUAY_OAUTH_TOKEN=$(cat /usr/local/ci-secrets/redhat-appstudio-qe/quay-oauth-token)
QUAY_OAUTH_TOKEN_RELEASE_SOURCE=$(cat /usr/local/ci-secrets/redhat-appstudio-qe/quay-oauth-token-release-source)
QUAY_OAUTH_TOKEN_RELEASE_DESTINATION=$(cat /usr/local/ci-secrets/redhat-appstudio-qe/quay-oauth-token-release-destination)
OPENSHIFT_API="$(yq e '.clusters[0].cluster.server' $KUBECONFIG)"
OPENSHIFT_USERNAME="kubeadmin"
PREVIOUS_RATE_REMAINING=0
GITHUB_TOKENS_LIST="$(cat /usr/local/ci-secrets/redhat-appstudio-qe/github_accounts)"

# Chose github user with greatest rate limit remaining
# user stored: username:token,username:token
IFS=',' read -r -a GITHUB_ACCOUNTS_ARRAY <<< "$(cat /usr/local/ci-secrets/redhat-appstudio-qe/github_accounts)"
for account in "${GITHUB_ACCOUNTS_ARRAY[@]}"
do :
    IFS=':' read -r -a GITHUB_USERNAME_ARRAY <<< "$account"

    GH_RATE_REMAINING=$(curl -s \
    -H "Accept: application/vnd.github+json" \
    -H "Authorization: Bearer ${GITHUB_USERNAME_ARRAY[1]}"\
    https://api.github.com/rate_limit | jq ".rate.remaining")

    echo -e "[INFO ] user: ${GITHUB_USERNAME_ARRAY[0]} with rate limit remaining $GH_RATE_REMAINING"
    if [[ "${GH_RATE_REMAINING}" -ge "${PREVIOUS_RATE_REMAINING}" ]];then
        GITHUB_USER="${GITHUB_USERNAME_ARRAY[0]}"
        GITHUB_TOKEN="${GITHUB_USERNAME_ARRAY[1]}"
    fi
    PREVIOUS_RATE_REMAINING="${GH_RATE_REMAINING}"
done

echo -e "[INFO] Start tests with user: ${GITHUB_USER}"

## Login to the (hypershift) cluster
yq -i 'del(.clusters[].cluster.certificate-authority-data) | .clusters[].cluster.insecure-skip-tls-verify=true' $KUBECONFIG
if [[ -s "$KUBEADMIN_PASSWORD_FILE" ]]; then
    OPENSHIFT_PASSWORD="$(cat $KUBEADMIN_PASSWORD_FILE)"
elif [[ -s "${SHARED_DIR}/kubeadmin-password" ]]; then
    # Recommendation from hypershift qe team in slack channel..
    OPENSHIFT_PASSWORD="$(cat ${SHARED_DIR}/kubeadmin-password)"
else
    echo "Kubeadmin password file is empty... Aborting job"
    exit 1
fi

timeout --foreground 5m bash  <<- "EOF"
    while ! oc login "$OPENSHIFT_API" -u "$OPENSHIFT_USERNAME" -p "$OPENSHIFT_PASSWORD" --insecure-skip-tls-verify=true; do
            sleep 20
    done
EOF
  if [ $? -ne 0 ]; then
	  echo "Timed out waiting for login"
	  exit 1
  fi

# Clone e2e-tests repo and install cluster
git config --global user.name "redhat-appstudio-qe-bot"
git config --global user.email redhat-appstudio-qe-bot@redhat.com

mkdir -p "${HOME}/creds"
GIT_CREDS_PATH="${HOME}/creds/file"
git config --global credential.helper "store --file ${GIT_CREDS_PATH}"
echo "https://${GITHUB_USER}:${GITHUB_TOKEN}@github.com" > "${GIT_CREDS_PATH}"

cd "$(mktemp -d)"

git clone --branch main "https://${GITHUB_TOKEN}@github.com/redhat-appstudio/e2e-tests.git" .
./mage -v ci:prepareE2Ebranch
./mage -v bootstrapCluster
