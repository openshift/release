#!/usr/bin/env bash
set -o errexit
set -o nounset
set -o pipefail

export OPENSHIFT_API \
  OPENSHIFT_PASSWORD \
  NAMESPACE \
  GITHUB__APP__ID \
  GITHUB__APP__CLIENT__ID \
  GITHUB__APP__CLIENT__SECRET \
  GITOPS__GIT_TOKEN \
  GITHUB__APP__WEBHOOK__SECRET \
  GITLAB__TOKEN \
  QUAY__DOCKERCONFIGJSON \
  QUAY__API_TOKEN \
  ACS__CENTRAL_ENDPOINT \
  ACS__API_TOKEN

OPENSHIFT_API="$(yq e '.clusters[0].cluster.server' $KUBECONFIG)"
NAMESPACE=rhtap
GITHUB__APP__ID=$(cat /usr/local/rhtap-ci-secrets/rhtap/rhdh-github-app-id)
GITHUB__APP__CLIENT__ID=$(cat /usr/local/rhtap-ci-secrets/rhtap/rhdh-github-client-id)
GITHUB__APP__CLIENT__SECRET=$(cat /usr/local/rhtap-ci-secrets/rhtap/rhdh-github-client-secret)
GITHUB__APP__PRIVATE_KEY=$(base64 -d < /usr/local/rhtap-ci-secrets/rhtap/rhdh-github-private-key | sed 's/^/        /')
GITOPS__GIT_TOKEN=$(cat /usr/local/rhtap-ci-secrets/rhtap/gihtub_token)
GITHUB__APP__WEBHOOK__SECRET=$(cat /usr/local/rhtap-ci-secrets/rhtap/rhdh-github-webhook-secret)
GITLAB__TOKEN=$(cat /usr/local/rhtap-ci-secrets/rhtap/gitlab_token)
QUAY__DOCKERCONFIGJSON=$(cat /usr/local/rhtap-ci-secrets/rhtap/rhtap_quay_ci_token)
QUAY__API_TOKEN=$(cat /usr/local/rhtap-ci-secrets/rhtap/quay_api_token)
ACS__API_TOKEN=$(cat /usr/local/rhtap-ci-secrets/rhtap/acs-api-token)
ACS__CENTRAL_ENDPOINT=$(cat /usr/local/rhtap-ci-secrets/rhtap/acs-central-endpoint)

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

configure_rhtap(){

  echo "make build"
  make build

  # Path to your values.yaml.tpl file
  tpl_file="installer/charts/values.yaml.tpl"

  # Turn ci to true
  sed -i 's/ci: false/ci: true/' $tpl_file

  cat <<EOF >> $tpl_file
integrations:
  github:
    id: "${GITHUB__APP__ID}"
    clientId: "${GITHUB__APP__CLIENT__ID}"
    clientSecret: "${GITHUB__APP__CLIENT__SECRET}"
    publicKey: |-
$(echo "${GITHUB__APP__PRIVATE_KEY}" | sed 's/^/      /')
    token: "${GITOPS__GIT_TOKEN}"
    webhookSecret: "${GITHUB__APP__WEBHOOK__SECRET}"
EOF

  # Edit config.yaml
  config_file="installer/config.yaml"
  sed -i '/redHatAdvancedClusterSecurity:/,/namespace: rhtap-acs/ s/^\(\s*enabled:.*\)$/#\1/' $config_file
  sed -i '/redHatQuay:/,/namespace: rhtap-quay/ s/^\(\s*enabled:.*\)$/#\1/' $config_file
  sed -i 's|/release/|/main/|' $config_file

}

configure_rhtap_for_prerelease_versions(){
  # Prepare for pre-release install capabilities
  # Define the file path
  subscription_values_file="installer/charts/rhtap-subscriptions/values.yaml"

  # Function to update the values
  update_values() {
    local section=$1
    local channel=$2
    local source=$3

    sed -i "/$section:/,/sourceNamespace:/ {
      /^ *channel:/ s/: .*/: $channel/
      /^ *source:/ s/: .*/: $source/
    }" $subscription_values_file
  }

  echo "Check the PRODUCT variable and update the corresponding section"
  if [ "$PRODUCT" == "gitops" ]; then
    update_values "openshiftGitOps" "$NEW_OPERATOR_CHANNEL" "$NEW_SOURCE"
  elif [ "$PRODUCT" == "rhdh" ]; then
    update_values "redHatDeveloperHub" "$NEW_OPERATOR_CHANNEL" "$NEW_SOURCE"
  elif [ "$PRODUCT" == "pipelines" ]; then
    update_values "openshiftPipelines" "$NEW_OPERATOR_CHANNEL" "$NEW_SOURCE"
  else
    echo "No prerelease product specified nothing needs doing."
  fi
  
  echo "Show subscription values"
  cat $subscription_values_file

}

install_rhtap(){
  echo "install"
  ./bin/rhtap-cli integration --kube-config "$KUBECONFIG" quay --url="https://quay.io" --dockerconfigjson="${QUAY__DOCKERCONFIGJSON}" --token="${QUAY__API_TOKEN}"
  ./bin/rhtap-cli integration --kube-config "$KUBECONFIG" acs --endpoint="${ACS__CENTRAL_ENDPOINT}" --token="${ACS__API_TOKEN}"
  ./bin/rhtap-cli integration --kube-config "$KUBECONFIG" gitlab --token "${GITLAB__TOKEN}"
  
  ./bin/rhtap-cli deploy --config ./installer/config.yaml --kube-config "$KUBECONFIG" | tee /tmp/command_output.txt


  WEBHOOK_URL="https://$(oc get routes -n openshift-pipelines pipelines-as-code-controller -ojsonpath='{.spec.host}')"
  HOMEPAGE_URL="https://$(oc get routes -n rhtap backstage-developer-hub  -ojsonpath='{.spec.host}')"
  CALLBACK_URL="https://$(oc get routes -n rhtap backstage-developer-hub  -ojsonpath='{.spec.host}'/api/auth/github/handler/frame)"

  echo "$WEBHOOK_URL" | tee "${SHARED_DIR}/webhook_url"
  echo "$HOMEPAGE_URL" | tee "${SHARED_DIR}/homepage_url"
  echo "$CALLBACK_URL" | tee "${SHARED_DIR}/callback_url"
}

show_installed_versions(){
  namespace=rhtap

  oc get csv -n "$namespace" -o json | jq -r '
    .items[] | {
      name: .metadata.name,
      version: .spec.version,
      containerImage: .metadata.annotations.containerImage
    } |
    "Operator: \(.name)\nVersion: \(.version)\nImage: \(.containerImage)\n-----------------------------------------"
  '| tee -a $SHARED_DIR/installed_versions.txt

  cp $SHARED_DIR/installed_versions.txt "${ARTIFACT_DIR}/installed_versions.txt"
}

configure_rhtap
configure_rhtap_for_prerelease_versions
install_rhtap
show_installed_versions
