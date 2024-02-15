#!/usr/bin/env bash
set -o errexit
set -o nounset
set -o pipefail

DEBUG_OUTPUT=/tmp/log.txt
export ACS__API_TOKEN ACS__CENTRAL_ENDPOINT DEVELOPER_HUB__CATALOG__URL GITHUB__APP__APP_ID GITHUB__APP__CLIENT_ID GITHUB__APP__CLIENT_SECRET \
    GITHUB__APP__WEBHOOK_SECRET GITHUB__APP__WEBHOOK_URL GITHUB__APP__PRIVATE_KEY TRUSTIFICATION__GUAC__PASSWORD TRUSTIFICATION__KEYCLOAK__ADMIN_PASSWORD \
    TRUSTIFICATION__MINIO__ROOT_PASSWORD TRUSTIFICATION__OIDC__TESTING_MANAGER_CLIENT_SECRET TRUSTIFICATION__OIDC__TESTING_USER_CLIENT_SECRET \
    TRUSTIFICATION__OIDC__WALKER_CLIENT_SECRET TRUSTIFICATION__POSTGRES__POSTGRES_PASSWORD TRUSTIFICATION__POSTGRES__TRUSTIFICATION_PASSWORD \
    TPA__GUAC__PASSWORD TPA__KEYCLOAK__ADMIN_PASSWORD TPA__MINIO__ROOT_PASSWORD TPA__OIDC__TESTING_MANAGER_CLIENT_SECRET TPA__OIDC__TESTING_USER_CLIENT_SECRET \
    TPA__OIDC__WALKER_CLIENT_SECRET TPA__POSTGRES__POSTGRES_PASSWORD TPA__POSTGRES__TPA_PASSWORD
ACS__API_TOKEN=$(cat /usr/local/rhtap-ci-secrets/rhtap/acs-api-token)
ACS__CENTRAL_ENDPOINT=$(cat /usr/local/rhtap-ci-secrets/rhtap/acs-central-endpoint)
DEVELOPER_HUB__CATALOG__URL=https://github.com/redhat-appstudio/tssc-sample-templates/blob/main/all.yaml
GITHUB__APP__APP_ID=$(cat /usr/local/rhtap-ci-secrets/rhtap/rhdh-github-app-id)
GITHUB__APP__CLIENT_ID=$(cat /usr/local/rhtap-ci-secrets/rhtap/rhdh-github-client-id)
GITHUB__APP__CLIENT_SECRET=$(cat /usr/local/rhtap-ci-secrets/rhtap/rhdh-github-client-secret)
GITHUB__APP__WEBHOOK_SECRET=$(cat /usr/local/rhtap-ci-secrets/rhtap/rhdh-github-webhook-secret)
GITHUB__APP__WEBHOOK_URL=GITHUB_APP_WEBHOOK_URL
GITHUB__APP__PRIVATE_KEY=$(base64 -d < /usr/local/rhtap-ci-secrets/rhtap/rhdh-github-private-key)
SPRAYPROXY_SERVER_URL=$(cat /usr/local/rhtap-ci-secrets/rhtap/sprayproxy-server-url)
SPRAYPROXY_SERVER_TOKEN=$(cat /usr/local/rhtap-ci-secrets/rhtap/sprayproxy-server-token)
TRUSTIFICATION__GUAC__PASSWORD=123456
TRUSTIFICATION__KEYCLOAK__ADMIN_PASSWORD=123456
TRUSTIFICATION__MINIO__ROOT_PASSWORD=123456
TRUSTIFICATION__OIDC__TESTING_MANAGER_CLIENT_SECRET=123456
TRUSTIFICATION__OIDC__TESTING_USER_CLIENT_SECRET=123456
TRUSTIFICATION__OIDC__WALKER_CLIENT_SECRET=123456
TRUSTIFICATION__POSTGRES__POSTGRES_PASSWORD=123456
TRUSTIFICATION__POSTGRES__TRUSTIFICATION_PASSWORD=123456
TPA__GUAC__PASSWORD=123456
TPA__KEYCLOAK__ADMIN_PASSWORD=123456
TPA__MINIO__ROOT_PASSWORD=123456
TPA__OIDC__TESTING_MANAGER_CLIENT_SECRET=123456
TPA__OIDC__TESTING_USER_CLIENT_SECRET=123456
TPA__OIDC__WALKER_CLIENT_SECRET=123456
TPA__POSTGRES__POSTGRES_PASSWORD=123456
TPA__POSTGRES__TPA_PASSWORD=123456

NAMESPACE=rhtap

clone_repo(){
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

  echo "[INFO]Install RHTAP ..."
  ./bin/make.sh apply -n $NAMESPACE -- --values private-values.yaml

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

  echo "homepage-url: $homepage_url"
  echo "callback-url: $callback_url"
  echo "webhook-url: $webhook_url"
}

register_pac_server(){
  echo "Registering PAC server to SprayProxy server"
  for _ in {1..5}; do
    if curl -k -X POST -H "Authorization: Bearer ${SPRAYPROXY_SERVER_TOKEN}" "${SPRAYPROXY_SERVER_URL}"/backends --data '{"url": "'"$webhook_url"'"}'; then
      break
    fi
    sleep 5
  done
}

unregister_pac_server(){
  echo "Unregistering PAC server from SprayProxy server"
  for _ in {1..5}; do
    if curl -k -X DELETE -H "Authorization: Bearer ${SPRAYPROXY_SERVER_TOKEN}" "${SPRAYPROXY_SERVER_URL}"/backends/"$webhook_url" --data '{"url": "'"$webhook_url"'"}'; then
      break
    fi
    sleep 5
  done
}

list_pac_server(){
  echo "List PAC server from SprayProxy server"
  for _ in {1..5}; do
    if curl -k -X GET -H "Authorization: Bearer ${SPRAYPROXY_SERVER_TOKEN}" "${SPRAYPROXY_SERVER_URL}"/backends; then
      break
    fi
    sleep 5
  done
}

e2e_test(){
  echo "[INFO]Trigger installer sanity tests..."
  # ./test/e2e.sh -t test -- --values private-values.yaml
  ./bin/make.sh -n "$NAMESPACE" test
}

clone_repo
install_rhtap
register_pac_server
list_pac_server
e2e_test
unregister_pac_server
