#!/usr/bin/env bash
set -o errexit
set -o nounset
set -o pipefail

DEBUG_OUTPUT=/tmp/log.txt

export ACS__API_TOKEN \
  ACS__CENTRAL_ENDPOINT \
  DEVELOPER_HUB__CATALOG__URL \
  GITHUB__APP__APP_ID GITHUB__APP__CLIENT_ID \
  GITHUB__APP__CLIENT_SECRET \
  GITHUB__APP__WEBHOOK_SECRET \
  GITHUB__APP__WEBHOOK_URL \
  GITHUB__APP__PRIVATE_KEY \
  GITOPS__GIT_TOKEN \
  QUAY__DOCKERCONFIGJSON \
  TPA__GUAC__PASSWORD \
  TPA__KEYCLOAK__ADMIN_PASSWORD \
  TPA__MINIO__ROOT_PASSWORD \
  TPA__OIDC__TESTING_MANAGER_CLIENT_SECRET \
  TPA__OIDC__TESTING_USER_CLIENT_SECRET \
  TPA__OIDC__WALKER_CLIENT_SECRET \
  TPA__POSTGRES__POSTGRES_PASSWORD \
  TPA__POSTGRES__TPA_PASSWORD \
  SPRAYPROXY_SERVER_URL \
  SPRAYPROXY_SERVER_TOKEN \
  DEVELOPER_HUB__QUAY_TOKEN__ASK_THE_INSTALLER_DEV_TEAM \
  OPENSHIFT_API \
  OPENSHIFT_PASSWORD \
  TAS__SECURESIGN__FULCIO__ORG_EMAIL \
  TAS__SECURESIGN__FULCIO__ORG_NAME \
  TAS__SECURESIGN__FULCIO__OIDC__URL \
  TAS__SECURESIGN__FULCIO__OIDC__CLIENT_ID \
  TAS__SECURESIGN__FULCIO__OIDC__TYPE \
  RHTAP_ENABLE_GITHUB \
  RHTAP_ENABLE_GITLAB \
  RHTAP_ENABLE_DEVELOPER_HUB \
  RHTAP_ENABLE_TAS \
  RHTAP_ENABLE_TAS_FULCIO_OIDC_DEFAULT_VALUES \
  RHTAP_ENABLE_TPA

RHTAP_ENABLE_GITHUB=${RHTAP_ENABLE_GITHUB:-'true'} 
RHTAP_ENABLE_GITLAB=${RHTAP_ENABLE_GITLAB:-'false'}
RHTAP_ENABLE_DEVELOPER_HUB=${RHTAP_ENABLE_DEVELOPER_HUB:-'true'}
RHTAP_ENABLE_TAS=${RHTAP_ENABLE_TAS:-'true'}
RHTAP_ENABLE_TAS_FULCIO_OIDC_DEFAULT_VALUES=${RHTAP_ENABLE_TAS_FULCIO_OIDC_DEFAULT_VALUES:-'true'}
RHTAP_ENABLE_TPA=${RHTAP_ENABLE_TPA:-'true'}

ACS__API_TOKEN=$(cat /usr/local/rhtap-ci-secrets/rhtap/acs-api-token)
ACS__CENTRAL_ENDPOINT=$(cat /usr/local/rhtap-ci-secrets/rhtap/acs-central-endpoint)
DEVELOPER_HUB__CATALOG__URL=https://github.com/redhat-appstudio/tssc-sample-templates/blob/main/all.yaml
GITHUB__APP__APP_ID=$(cat /usr/local/rhtap-ci-secrets/rhtap/rhdh-github-app-id)
GITHUB__APP__CLIENT_ID=$(cat /usr/local/rhtap-ci-secrets/rhtap/rhdh-github-client-id)
GITHUB__APP__CLIENT_SECRET=$(cat /usr/local/rhtap-ci-secrets/rhtap/rhdh-github-client-secret)
GITHUB__APP__WEBHOOK_SECRET=$(cat /usr/local/rhtap-ci-secrets/rhtap/rhdh-github-webhook-secret)
GITHUB__APP__WEBHOOK_URL=GITHUB_APP_WEBHOOK_URL
GITHUB__APP__PRIVATE_KEY=$(base64 -d < /usr/local/rhtap-ci-secrets/rhtap/rhdh-github-private-key)
GITOPS__GIT_TOKEN=$(cat /usr/local/rhtap-ci-secrets/rhtap/gihtub_token)
QUAY__DOCKERCONFIGJSON=$(cat /usr/local/rhtap-ci-secrets/rhtap/rhtap_quay_ci_token)
SPRAYPROXY_SERVER_URL=$(cat /usr/local/rhtap-ci-secrets/rhtap/sprayproxy-server-url)
SPRAYPROXY_SERVER_TOKEN=$(cat /usr/local/rhtap-ci-secrets/rhtap/sprayproxy-server-token)
DEVELOPER_HUB__QUAY_TOKEN__ASK_THE_INSTALLER_DEV_TEAM=$(cat /usr/local/rhtap-ci-secrets/rhtap/quay-token)

TPA__GUAC__PASSWORD="guac1234" # notsecret
TPA__KEYCLOAK__ADMIN_PASSWORD="admin123456" # notsecret
TPA__MINIO__ROOT_PASSWORD="minio123456" # notsecret
TPA__OIDC__TESTING_MANAGER_CLIENT_SECRET="ca48053c-3b82-4650-a98d-4cace7f2d567" # notsecret
TPA__OIDC__TESTING_USER_CLIENT_SECRET="0e6bf990-43b4-4efb-95d7-b24f2b94a525" # notsecret
TPA__OIDC__WALKER_CLIENT_SECRET="5460cc91-4e20-4edd-881c-b15b169f8a79" # notsecret
TPA__POSTGRES__POSTGRES_PASSWORD="postgres123456" # notsecret
TPA__POSTGRES__TPA_PASSWORD="postgres1234" # notsecret
OPENSHIFT_API="$(yq e '.clusters[0].cluster.server' $KUBECONFIG)"
TAS__SECURESIGN__FULCIO__ORG_EMAIL='rhtap-qe-ci@redhat.com'
TAS__SECURESIGN__FULCIO__ORG_NAME='RHTAP CI Jobs'
TAS__SECURESIGN__FULCIO__OIDC__URL='http://localhost:3030'
TAS__SECURESIGN__FULCIO__OIDC__CLIENT_ID="fake-one"
TAS__SECURESIGN__FULCIO__OIDC__TYPE="dex"
NAMESPACE=rhtap

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

clone_repo(){
  if [[ "${JOB_NAME}" == *"redhat-appstudio-rhtap-installer"* ]]; then
    echo "[INFO]Skip cloning rhtap-installer repo..."
    return
  fi
  echo "[INFO]Cloning rhtap-installer repo..."
  git clone https://github.com/redhat-appstudio/rhtap-installer.git
  cd rhtap-installer
}

wait_for_pipeline() {
  if ! oc wait --for=condition=succeeded "$1" -n "$2" --timeout 300s >"$DEBUG_OUTPUT"; then
    echo "[ERROR] Pipeline failed to complete successful" >&2
    oc get pipelineruns "$1" -n "$2" >"$DEBUG_OUTPUT"
    exit 1
  fi
}

install_rhtap(){
  echo "[INFO]Generate private-values.yaml file ..."
  ./bin/make.sh values
  # enable debug model
  yq e -i '.debug.script=true' private-values.yaml
  echo "[INFO]Install RHTAP ..."
  ./bin/make.sh apply -d -n $NAMESPACE -- --values private-values.yaml

  echo ""
  echo "[INFO]Extract the configuration information from logs of the pipeline"
  cat << EOF > rhtap-pe-info.yaml
    apiVersion: tekton.dev/v1
    kind: PipelineRun
    metadata:
      generateName: rhtap-pe-info-
      namespace: "$NAMESPACE"
    spec:
      pipelineSpec:
        tasks:
          - name: configuration-info
            taskRef:
              resolver: cluster
              params:
                - name: kind
                  value: task
                - name: name
                  value: rhtap-pe-info
                - name: namespace
                  value: "$NAMESPACE"
EOF

  pipeline_name=$(oc create -f rhtap-pe-info.yaml | cut -d' ' -f1 | awk -F'/' '{print $2}')
  wait_for_pipeline "pipelineruns/$pipeline_name" "$NAMESPACE"
  tkn -n "$NAMESPACE" pipelinerun logs "$pipeline_name" -f >"$DEBUG_OUTPUT"

  homepage_url=$(grep "homepage-url" < "$DEBUG_OUTPUT" | sed 's/.*: //g')
  callback_url=$(grep "callback-url" < "$DEBUG_OUTPUT" | sed 's/.*: //g')
  webhook_url=$(grep "webhook-url" < "$DEBUG_OUTPUT"  | sed 's/.*: //g') 

  echo "$homepage_url" | tee "${SHARED_DIR}/homepage_url"
  echo "$callback_url" | tee "${SHARED_DIR}/callback_url"
  echo "$webhook_url" | tee "${SHARED_DIR}/webhook_url"
}

e2e_test(){
  echo "[INFO]Trigger installer sanity tests..."
  ./bin/make.sh -n "$NAMESPACE" test
}

clone_repo
install_rhtap
e2e_test
