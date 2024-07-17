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
  QUAY__API_TOKEN

OPENSHIFT_API="$(yq e '.clusters[0].cluster.server' $KUBECONFIG)"
NAMESPACE=rhtap
GITHUB__APP__ID=$(cat /usr/local/rhtap-ci-secrets/rhtap/rhdh-github-app-id)
GITHUB__APP__CLIENT__ID=$(cat /usr/local/rhtap-ci-secrets/rhtap/rhdh-github-client-id)
GITHUB__APP__CLIENT__SECRET=$(cat /usr/local/rhtap-ci-secrets/rhtap/rhdh-github-client-secret)
GITHUB__APP__PRIVATE_KEY=$(base64 -d < /usr/local/rhtap-ci-secrets/rhtap/rhdh-github-private-key)
GITOPS__GIT_TOKEN=$(cat /usr/local/rhtap-ci-secrets/rhtap/gihtub_token)
GITHUB__APP__WEBHOOK__SECRET=$(cat /usr/local/rhtap-ci-secrets/rhtap/rhdh-github-webhook-secret)
GITLAB__TOKEN=$(cat /usr/local/rhtap-ci-secrets/rhtap/gitlab_token)
QUAY__DOCKERCONFIGJSON=$(cat /usr/local/rhtap-ci-secrets/rhtap/rhtap_quay_ci_token)
QUAY__API_TOKEN=$(cat /usr/local/rhtap-ci-secrets/rhtap/quay_api_token)

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

install_rhtap(){
  echo -e "INFO: cloning repo"
  echo "git clone"
  git clone $GIT_URL
  echo "git checkout"
  git checkout $GIT_REVISION

  # Path to your values.yaml.tpl file
  tpl_file="rhtap-cli/charts/values.yaml.tpl"

  # Create the new integrations section
  new_integrations=$(cat <<EOF
  integrations:
    github:
      id: "${GITHUB__APP__ID}"
      clientId: "${GITHUB__APP__CLIENT__ID}"
      clientSecret: "${GITHUB__APP__CLIENT__SECRET}"
      publicKey: |
  $(echo "${GITHUB__APP__PRIVATE_KEY}" | sed 's/^/      /')
      token: "${GITOPS__GIT_TOKEN}"
      webhookSecret: "${GITHUB__APP__WEBHOOK__SECRET}"
    gitlab:
      token: "${GITLAB__TOKEN}"
    quay:
      dockerconfigjson: |
  $(echo "${QUAY__DOCKERCONFIGJSON}" | sed 's/^/      /')
      token: "${QUAY__API_TOKEN}"
EOF
  )

  # Use awk to replace the integrations section
  awk -v new_integrations="$new_integrations" '
    BEGIN { found = 0 }
    /^# integrations:/ { found = 1; print new_integrations; next }
    found && /^# rhtap-dh/ { found = 0 }
    !found { print }
  ' "$tpl_file" > tmpfile && mv tmpfile "$tpl_file"

  echo "make build"
  make build

  echo "install"
  ./bin/rhtap-cli deploy --config ./config.yaml --kube-config "$KUBECONFIG" | tee /tmp/command_output.txt

  # Check if "Deployment complete" is in the output
  if grep -q "Developer Hub deployed" /tmp/command_output.txt; then
    echo "Deployment completed"
  else
    echo "Deployment did not complete"
    exit 1
  fi

  webhook_url="https://$(oc get routes -n openshift-pipelines pipelines-as-code-controller -ojsonpath='{.spec.host}')"

  echo "$webhook_url" | tee "${SHARED_DIR}/webhook_url"

}

install_rhtap
