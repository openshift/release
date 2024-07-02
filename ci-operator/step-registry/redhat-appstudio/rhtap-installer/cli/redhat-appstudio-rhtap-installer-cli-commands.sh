#!/usr/bin/env bash
set -o errexit
set -o nounset
set -o pipefail

export OPENSHIFT_API \
  OPENSHIFT_PASSWORD \

# RHTAP_ENABLE_GITHUB=${RHTAP_ENABLE_GITHUB:-'true'}
# RHTAP_ENABLE_GITLAB=${RHTAP_ENABLE_GITLAB:-'true'}
# RHTAP_ENABLE_DEVELOPER_HUB=${RHTAP_ENABLE_DEVELOPER_HUB:-'true'}
# RHTAP_ENABLE_TAS=${RHTAP_ENABLE_TAS:-'true'}
# RHTAP_ENABLE_TAS_FULCIO_OIDC_DEFAULT_VALUES=${RHTAP_ENABLE_TAS_FULCIO_OIDC_DEFAULT_VALUES:-'true'}
# RHTAP_ENABLE_TPA=${RHTAP_ENABLE_TPA:-'true'}

# echo "Enabled Components....."
# env | grep '^RHTAP_ENABLE'

# ACS__API_TOKEN=$(cat /usr/local/rhtap-ci-secrets/rhtap/acs-api-token)
# ACS__CENTRAL_ENDPOINT=$(cat /usr/local/rhtap-ci-secrets/rhtap/acs-central-endpoint)
# DEVELOPER_HUB__CATALOG__URL=https://github.com/redhat-appstudio/tssc-sample-templates/blob/main/all.yaml
# GITHUB__APP__ID=$(cat /usr/local/rhtap-ci-secrets/rhtap/rhdh-github-app-id)
# GITHUB__APP__CLIENT__ID=$(cat /usr/local/rhtap-ci-secrets/rhtap/rhdh-github-client-id)
# GITHUB__APP__CLIENT__SECRET=$(cat /usr/local/rhtap-ci-secrets/rhtap/rhdh-github-client-secret)
# GITHUB__APP__WEBHOOK__SECRET=$(cat /usr/local/rhtap-ci-secrets/rhtap/rhdh-github-webhook-secret)
# GITHUB__APP__PRIVATE_KEY=$(base64 -d < /usr/local/rhtap-ci-secrets/rhtap/rhdh-github-private-key)
# GITOPS__GIT_TOKEN=$(cat /usr/local/rhtap-ci-secrets/rhtap/gihtub_token)
# QUAY__DOCKERCONFIGJSON=$(cat /usr/local/rhtap-ci-secrets/rhtap/rhtap_quay_ci_token)
# SPRAYPROXY_SERVER_URL=$(cat /usr/local/rhtap-ci-secrets/rhtap/sprayproxy-server-url)
# SPRAYPROXY_SERVER_TOKEN=$(cat /usr/local/rhtap-ci-secrets/rhtap/sprayproxy-server-token)
# GITLAB__APP__CLIENT__ID=$(cat /usr/local/rhtap-ci-secrets/rhtap/gitlab_oauth_client_id)
# GITLAB__APP__CLIENT__SECRET=$(cat /usr/local/rhtap-ci-secrets/rhtap/gitlab_oauth_client_secret)
# GITLAB__TOKEN=$(cat /usr/local/rhtap-ci-secrets/rhtap/gitlab_token)
# QUAY__API_TOKEN=$(cat /usr/local/rhtap-ci-secrets/rhtap/quay_api_token)

# TPA__GUAC__PASSWORD="guac1234" # notsecret
# TPA__KEYCLOAK__ADMIN_PASSWORD="admin123456" # notsecret
# TPA__MINIO__ROOT_PASSWORD="minio123456" # notsecret
# TPA__OIDC__TESTING_MANAGER_CLIENT_SECRET="ca48053c-3b82-4650-a98d-4cace7f2d567" # notsecret
# TPA__OIDC__TESTING_USER_CLIENT_SECRET="0e6bf990-43b4-4efb-95d7-b24f2b94a525" # notsecret
# TPA__OIDC__WALKER_CLIENT_SECRET="5460cc91-4e20-4edd-881c-b15b169f8a79" # notsecret
# TPA__POSTGRES__POSTGRES_PASSWORD="postgres123456" # notsecret
# TPA__POSTGRES__TPA_PASSWORD="postgres1234" # notsecret
# OPENSHIFT_API="$(yq e '.clusters[0].cluster.server' $KUBECONFIG)"
# TAS__SECURESIGN__FULCIO__ORG_EMAIL='rhtap-qe-ci@redhat.com'
# TAS__SECURESIGN__FULCIO__ORG_NAME='RHTAP CI Jobs'
# TAS__SECURESIGN__FULCIO__OIDC__URL='http://localhost:3030'
# TAS__SECURESIGN__FULCIO__OIDC__CLIENT_ID="fake-one"
# TAS__SECURESIGN__FULCIO__OIDC__TYPE="dex"
# NAMESPACE=rhtap

yq -i 'del(.clusters[].cluster.certificate-authority-data) | .clusters[].cluster.insecure-skip-tls-verify=true' "$KUBECONFIG"
OPENSHIFT_PASSWORD="$(cat $KUBEADMIN_PASSWORD_FILE)"

timeout --foreground 5m bash  <<- "EOF"
    while ! oc login "$OPENSHIFT_API" -u kubeadmin -p "$OPENSHIFT_PASSWORD" --insecure-skip-tls-verify=true; do
            sleep 20
    done
EOF

if [ $? -ne 0 ]; then
  echo "Timed out waiting for login"
  exit 1
fi

# clone_repo(){
#   if [[ "${JOB_NAME}" == *"redhat-appstudio-rhtap-installer"* ]]; then
#     echo "[INFO]Skip cloning rhtap-installer repo..."
#     return
#   fi
#   echo "[INFO]Cloning rhtap-installer repo..."
#   git clone https://github.com/redhat-appstudio/rhtap-installer.git
#   cd rhtap-installer
# }

# wait_for_pipeline() {
#   if ! oc wait --for=condition=succeeded "$1" -n "$2" --timeout 300s >"$DEBUG_OUTPUT"; then
#     echo "[ERROR] Pipeline failed to complete successful" >&2
#     oc get pipelineruns "$1" -n "$2" >"$DEBUG_OUTPUT"
#     exit 1
#   fi
# }

install_rhtap(){
  echo -e "INFO: cloning repo name '$(params.git-repo)' with revision '$(params.git-revision)' from url '$(params.git-url)'"
  echo "git clone"
  git clone "$(params.git-url)" .
  echo "git checkout"
  git checkout "$(params.git-revision)"
  echo "make build"
  make build
  echo "install"
  ./bin/rhtap-cli deploy --config ./config.yaml --kube-config "$KUBECONFIG" --debug
}

# e2e_test(){
#   echo "[INFO]Trigger installer sanity tests..."
#   ./bin/make.sh -n "$NAMESPACE" test
# }

# verify_template(){
#   echo "[INFO]Verify the template..."
#   ./test/e2e.sh -t template
# }

# clone_repo
# verify_template
install_rhtap
# e2e_test
