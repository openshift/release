#!/bin/bash

set -o nounset
set -o errexit
set -o pipefail

export PATH=$PATH:/tmp/bin
mkdir -p /tmp/bin

export DEFAULT_QUAY_ORG DEFAULT_QUAY_ORG_TOKEN GITHUB_USER GITHUB_TOKEN QUAY_TOKEN QUAY_OAUTH_USER QUAY_OAUTH_TOKEN QUAY_OAUTH_TOKEN_RELEASE_SOURCE QUAY_OAUTH_TOKEN_RELEASE_DESTINATION OPENSHIFT_API OPENSHIFT_USERNAME OPENSHIFT_PASSWORD \
    GITHUB_ACCOUNTS_ARRAY PREVIOUS_RATE_REMAINING GITHUB_USERNAME_ARRAY GH_RATE_REMAINING PYXIS_STAGE_KEY PYXIS_STAGE_CERT BYOC_KUBECONFIG GITHUB_TOKENS_LIST OAUTH_REDIRECT_PROXY_URL

DEFAULT_QUAY_ORG=$(cat /usr/local/ci-secrets/redhat-appstudio-load-test/default-quay-org)
DEFAULT_QUAY_ORG_TOKEN=$(cat /usr/local/ci-secrets/redhat-appstudio-load-test/default-quay-org-token)
GITHUB_USER=""
GITHUB_TOKEN=""
GITHUB_TOKENS_LIST="$(cat /usr/local/ci-secrets/redhat-appstudio-load-test/github_accounts)"
QUAY_TOKEN=$(cat /usr/local/ci-secrets/redhat-appstudio-load-test/quay-token)
QUAY_OAUTH_USER=$(cat /usr/local/ci-secrets/redhat-appstudio-load-test/quay-oauth-user)
QUAY_OAUTH_TOKEN=$(cat /usr/local/ci-secrets/redhat-appstudio-load-test/quay-oauth-token)
QUAY_OAUTH_TOKEN_RELEASE_SOURCE=$(cat /usr/local/ci-secrets/redhat-appstudio-load-test/quay-oauth-token-release-source)
QUAY_OAUTH_TOKEN_RELEASE_DESTINATION=$(cat /usr/local/ci-secrets/redhat-appstudio-load-test/quay-oauth-token-release-destination)
OAUTH_REDIRECT_PROXY_URL=$(cat /usr/local/ci-secrets/redhat-appstudio-qe/oauth-redirect-proxy-url)
PYXIS_STAGE_KEY=$(cat /usr/local/ci-secrets/redhat-appstudio-qe/pyxis-stage-key)
PYXIS_STAGE_CERT=$(cat /usr/local/ci-secrets/redhat-appstudio-qe/pyxis-stage-cert)
OPENSHIFT_API="$(yq e '.clusters[0].cluster.server' $KUBECONFIG)"
OPENSHIFT_USERNAME="kubeadmin"
PREVIOUS_RATE_REMAINING=0

# user stored: username:token,username:token
IFS=',' read -r -a GITHUB_ACCOUNTS_ARRAY <<<"$(cat /usr/local/ci-secrets/redhat-appstudio-load-test/github_accounts)"
for account in "${GITHUB_ACCOUNTS_ARRAY[@]}"; do
    :
    IFS=':' read -r -a GITHUB_USERNAME_ARRAY <<<"$account"

    GH_RATE_REMAINING=$(curl -s \
        -H "Accept: application/vnd.github+json" \
        -H "Authorization: Bearer ${GITHUB_USERNAME_ARRAY[1]}" \
        https://api.github.com/rate_limit | jq ".rate.remaining")

    echo -e "[INFO ] user: ${GITHUB_USERNAME_ARRAY[0]} with rate limit remaining $GH_RATE_REMAINING"
    if [[ "${GH_RATE_REMAINING}" -ge "${PREVIOUS_RATE_REMAINING}" ]]; then
        GITHUB_USER="${GITHUB_USERNAME_ARRAY[0]}"
        GITHUB_TOKEN="${GITHUB_USERNAME_ARRAY[1]}"
    fi
    PREVIOUS_RATE_REMAINING="${GH_RATE_REMAINING}"
done

echo -e "[INFO] Start tests with user: ${GITHUB_USER}"

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

timeout --foreground 5m bash <<-"EOF"
    while ! oc login "$OPENSHIFT_API" -u "$OPENSHIFT_USERNAME" -p "$OPENSHIFT_PASSWORD" --insecure-skip-tls-verify=true; do
            sleep 20
    done
EOF
if [ $? -ne 0 ]; then
    echo "Timed out waiting for login"
    exit 1
fi

# Define a new environment for BYOC pointing to a kubeconfig with token. RHTAP environments only supports kubeconfig with token:
# See: https://issues.redhat.com/browse/GITOPSRVCE-554
BYOC_KUBECONFIG="/tmp/token-kubeconfig"
cp "$KUBECONFIG" "$BYOC_KUBECONFIG"
if [[ -s "$BYOC_KUBECONFIG" ]]; then
    echo -e "byoc kubeconfig exists!"
else
    echo "Kubeconfig not exists in $BYOC_KUBECONFIG... Aborting job"
    exit 1
fi

git config --global user.name "redhat-appstudio-qe-bot"
git config --global user.email redhat-appstudio-qe-bot@redhat.com

mkdir -p "${HOME}/creds"
GIT_CREDS_PATH="${HOME}/creds/file"
git config --global credential.helper "store --file ${GIT_CREDS_PATH}"
echo "https://${GITHUB_USER}:${GITHUB_TOKEN}@github.com" >"${GIT_CREDS_PATH}"

cd "$(mktemp -d)"

git clone --branch main "https://${GITHUB_TOKEN}@github.com/redhat-appstudio/e2e-tests.git" .

set -x
if [ "$JOB_TYPE" == "presubmit" ] && [[ "$JOB_NAME" != rehearse-* ]]; then
    # if this is executed as PR check of github.com/redhat-appstudio/e2e-tests.git repo, switch to PR branch.
    git fetch origin "pull/${PULL_NUMBER}/head"
    git checkout -b "pr-${PULL_NUMBER}" FETCH_HEAD
fi
set +x

# Collect load test results at the end
trap './tests/load-tests/ci-scripts/collect-results.sh "$SCENARIO"; trap EXIT' SIGINT EXIT

# Setup OpenShift cluster
./tests/load-tests/ci-scripts/setup-cluster.sh "$SCENARIO"

# Execute load test
./tests/load-tests/ci-scripts/load-test.sh "$SCENARIO"
