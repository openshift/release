#!/usr/bin/env bash
set -o errexit
set -o nounset
set -o pipefail
set -ex

DEBUG_OUTPUT=/tmp/log.txt

export ACS__API_TOKEN \
  ACS__CENTRAL_ENDPOINT \
  DEVELOPER_HUB__CATALOG__URL \
  GITHUB__APP__APP_ID GITHUB__APP__CLIENT_ID \
  GITHUB__APP__CLIENT_SECRET \
  GITHUB__APP__WEBHOOK_SECRET \
  GITHUB__APP__WEBHOOK_URL \
  GITHUB__APP__PRIVATE_KEY \
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
  AWS_ACCESS_KEY_ID \
  AWS_SECRET_ACCESS_KEY \
  OPENSHIFT_API \
  LE_API \
  LE_WILDCARD \
  OPENSHIFT_CONSOLE_URL \
  OPENSHIFT_PASSWORD

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
DEVELOPER_HUB__QUAY_TOKEN__ASK_THE_INSTALLER_DEV_TEAM=$(cat /usr/local/rhtap-ci-secrets/rhtap/quay-token)

TPA__GUAC__PASSWORD="guac1234" # notsecret
TPA__KEYCLOAK__ADMIN_PASSWORD="admin123456" # notsecret
TPA__MINIO__ROOT_PASSWORD="minio123456" # notsecret
TPA__OIDC__TESTING_MANAGER_CLIENT_SECRET="ca48053c-3b82-4650-a98d-4cace7f2d567" # notsecret
TPA__OIDC__TESTING_USER_CLIENT_SECRET="0e6bf990-43b4-4efb-95d7-b24f2b94a525" # notsecret
TPA__OIDC__WALKER_CLIENT_SECRET="5460cc91-4e20-4edd-881c-b15b169f8a79" # notsecret
TPA__POSTGRES__POSTGRES_PASSWORD="postgres123456" # notsecret
TPA__POSTGRES__TPA_PASSWORD="postgres1234" # notsecret

# Set your new AWS access key ID and secret access key
AWS_ACCESS_KEY_ID="$(cat /usr/local/rhtap-ci-secrets/rhtap/aws_access_key)"
AWS_SECRET_ACCESS_KEY="$(cat /usr/local/rhtap-ci-secrets/rhtap/aws_access_secret)"

OPENSHIFT_API="$(yq e '.clusters[0].cluster.server' $KUBECONFIG)"

if [ -z ${AWS_ACCESS_KEY_ID+x} ]; then
    echo "AWS_ACCESS_KEY_ID variable is not defined"
    exit 1
fi

if [ -z ${AWS_SECRET_ACCESS_KEY+x} ]; then
    echo "AWS_SECRET_ACCESS_KEY variable is not defined"
    exit 1
fi

## Login to the (hypershift) cluster
yq -i 'del(.clusters[].cluster.certificate-authority-data) | .clusters[].cluster.insecure-skip-tls-verify=true' $KUBECONFIG
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

export CERT_FOLDER="${HOME}/certificates"

# Run the command and store the result in a variable
OPENSHIFT_CONSOLE_URL=$(oc whoami --show-console)
if [ -n "$OPENSHIFT_CONSOLE_URL" ]; then
    OPENSHIFT_CONSOLE_URL="${OPENSHIFT_CONSOLE_URL#https://}"

    echo "OpenShift console URL set to: $OPENSHIFT_CONSOLE_URL"
else
    echo "Failed to retrieve OpenShift console URL."
    exit 1
fi

export LE_API=$(oc whoami --show-server | cut -f 2 -d ':' | cut -f 3 -d '/' | sed 's/-api././')
export LE_WILDCARD=$(oc get ingresscontroller default -n openshift-ingress-operator -o jsonpath='{.status.domain}')

# Remove the directory if it exists
if [ -d "$CERT_FOLDER/acme.sh" ]; then
    echo "Removing existing directory: $CERT_FOLDER/acme.sh"
    rm -rf "$CERT_FOLDER/acme.sh"
fi

git clone https://github.com/neilpang/acme.sh "${CERT_FOLDER}/acme.sh"

export CERT_DIR="$CERT_FOLDER"/certificates
rm -rf "${CERT_DIR}" && mkdir -p ${CERT_DIR}

# Uncomment and replace the AWS_ACCESS_KEY_ID and AWS_SECRET_ACCESS_KEY lines in the script if it's commented
sed -i -e "/^#AWS_ACCESS_KEY_ID/s/#//" ${CERT_FOLDER}/acme.sh/dnsapi/dns_aws.sh
sed -i -e "/^#AWS_SECRET_ACCESS_KEY/s/#//" ${CERT_FOLDER}/acme.sh/dnsapi/dns_aws.sh

# Replace the values with the new ones
sed -i -e "s|AWS_ACCESS_KEY_ID=\".*\"|AWS_ACCESS_KEY_ID=\"$AWS_ACCESS_KEY_ID\"|" ${CERT_FOLDER}/acme.sh/dnsapi/dns_aws.sh
sed -i -e "s|AWS_SECRET_ACCESS_KEY=\".*\"|AWS_SECRET_ACCESS_KEY=\"$AWS_SECRET_ACCESS_KEY\"|" ${CERT_FOLDER}/acme.sh/dnsapi/dns_aws.sh

"${CERT_FOLDER}"/acme.sh/acme.sh --force --register-account -m rhtap-qe-ci@stonesoupengineering.com

"${CERT_FOLDER}"/acme.sh/acme.sh --issue -d ${LE_API} -d *.${LE_WILDCARD} --dns dns_aws
"${CERT_FOLDER}"/acme.sh/acme.sh --install-cert -d ${LE_API} -d *.${LE_WILDCARD} --cert-file ${CERT_DIR}/cert.pem --key-file ${CERT_DIR}/key.pem --fullchain-file ${CERT_DIR}/fullchain.pem --ca-file ${CERT_DIR}/ca.cer

oc create secret tls router-certs --cert=${CERT_DIR}/fullchain.pem --key=${CERT_DIR}/key.pem -n openshift-ingress
oc patch ingresscontroller default -n openshift-ingress-operator --type=merge --patch='{"spec": { "defaultCertificate": { "name": "router-certs" }}}'

oc create secret tls api-certs --cert=${CERT_DIR}/fullchain.pem --key=${CERT_DIR}/key.pem -n openshift-config
oc patch apiserver cluster --type merge --patch="{\"spec\": {\"servingCerts\": {\"namedCertificates\": [ { \"names\": [  \"$LE_API\"  ], \"servingCertificate\": {\"name\": \"api-certs\" }}]}}}"

timeout_seconds=600
end_time=$((SECONDS + timeout_seconds))

while [ $SECONDS -lt $end_time ]; do
    # Connect to the domain and retrieve the certificate chain
    cert_chain=$(openssl s_client -connect "$OPENSHIFT_CONSOLE_URL:443" -servername "$OPENSHIFT_CONSOLE_URL" < /dev/null 2>/dev/null)

    # Check if the certificate chain contains the "Verify return code: 0 (ok)" message, indicating the certificate is trusted
    if [[ "$cert_chain" == *"Verify return code: 0 (ok)"* ]]; then
        echo "The certificate for $OPENSHIFT_CONSOLE_URL is trusted."
        break
    else
        echo "The certificate for $OPENSHIFT_CONSOLE_URL is not trusted."
    fi

    if [ $SECONDS -ge $end_time ]; then
        echo "Timeout reached. Certificate is still not trusted after $timeout_seconds seconds."
        break
    fi
done








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
  # enable debug model
  yq e -i '.debug.script=true' private-values.yaml
  #WA: disable TPA during installation to avoid bug https://issues.redhat.com/browse/RHTAPBUGS-1144 
  #yq e -i '.trusted-profile-analyzer=null' private-values.yaml
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

  echo "$homepage_url" > "${SHARED_DIR}/homepage_url"
  echo "$callback_url" > "${SHARED_DIR}/callback_url"
  echo "$webhook_url" > "${SHARED_DIR}/webhook_url"
}

e2e_test(){
  echo "[INFO]Trigger installer sanity tests..."
  ./bin/make.sh -n "$NAMESPACE" test
}

clone_repo
install_rhtap
e2e_test