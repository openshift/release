#!/bin/bash

set -o nounset
set -o errexit
set -o pipefail

if [ "$RHTAP_ENABLE_TPA" = "false" ]; then
    echo "RHTPA is disabled, skipping certificates creation..."
    exit 0
fi

export CERT_FOLDER AWS_ACCESS_KEY_ID AWS_SECRET_ACCESS_KEY OPENSHIFT_CONSOLE_URL \
    LE_API LE_WILDCARD CERT_DIR OPENSHIFT_PASSWORD OPENSHIFT_API

CERT_FOLDER="${HOME}/cert-manager"

AWS_ACCESS_KEY_ID="$(cat /usr/local/rhtap-ci-secrets/rhtap/aws_access_key)"
AWS_SECRET_ACCESS_KEY="$(cat /usr/local/rhtap-ci-secrets/rhtap/aws_access_secret)"

yq -i 'del(.clusters[].cluster.certificate-authority-data) | .clusters[].cluster.insecure-skip-tls-verify=true' $KUBECONFIG
OPENSHIFT_PASSWORD="$(cat $KUBEADMIN_PASSWORD_FILE)"
OPENSHIFT_API="$(yq e '.clusters[0].cluster.server' $KUBECONFIG)"

timeout --foreground 5m bash  <<- "EOF"
    while ! oc login "$OPENSHIFT_API" -u kubeadmin -p "$OPENSHIFT_PASSWORD" --insecure-skip-tls-verify=true; do
        sleep 20
    done
EOF

if [ $? -ne 0 ]; then
  echo "Timed out waiting for login"
  exit 1
fi

# Run the command and store the result in a variable
OPENSHIFT_CONSOLE_URL=$(oc whoami --show-console)
if [ -n "$OPENSHIFT_CONSOLE_URL" ]; then
    OPENSHIFT_CONSOLE_URL="${OPENSHIFT_CONSOLE_URL#https://}"

    echo "OpenShift console URL set to: $OPENSHIFT_CONSOLE_URL"
else
    echo "Failed to retrieve OpenShift console URL."
    exit 1
fi

LE_API=$(oc whoami --show-server | cut -f 2 -d ':' | cut -f 3 -d '/' | sed 's/-api././')
LE_WILDCARD=$(oc get ingresscontroller default -n openshift-ingress-operator -o jsonpath='{.status.domain}')

# Remove the directory if it exists
if [ -d "$CERT_FOLDER/acme.sh" ]; then
    echo "Removing existing directory: $CERT_FOLDER/acme.sh"
    rm -rf "$CERT_FOLDER/acme.sh"
fi

git clone https://github.com/neilpang/acme.sh "${CERT_FOLDER}/acme.sh"

CERT_DIR="$CERT_FOLDER"/cert-vault
rm -rf "${CERT_DIR}" && mkdir -p ${CERT_DIR}

# Uncomment and replace the AWS_ACCESS_KEY_ID and AWS_SECRET_ACCESS_KEY lines in the script if it's commented
sed -i -e "/^#AWS_ACCESS_KEY_ID/s/#//" "${CERT_FOLDER}"/acme.sh/dnsapi/dns_aws.sh
sed -i -e "/^#AWS_SECRET_ACCESS_KEY/s/#//" "${CERT_FOLDER}"/acme.sh/dnsapi/dns_aws.sh

# Replace the values with the new ones
sed -i -e "s|AWS_ACCESS_KEY_ID=\".*\"|AWS_ACCESS_KEY_ID=\"$AWS_ACCESS_KEY_ID\"|" "${CERT_FOLDER}"/acme.sh/dnsapi/dns_aws.sh
sed -i -e "s|AWS_SECRET_ACCESS_KEY=\".*\"|AWS_SECRET_ACCESS_KEY=\"$AWS_SECRET_ACCESS_KEY\"|" "${CERT_FOLDER}"/acme.sh/dnsapi/dns_aws.sh

"${CERT_FOLDER}"/acme.sh/acme.sh --register-account -m rhtap-qe-ci@ci.stonesoupengineering.com

"${CERT_FOLDER}"/acme.sh/acme.sh --issue -d ${LE_API}  -d *.${LE_WILDCARD} --server letsencrypt --dns dns_aws
"${CERT_FOLDER}"/acme.sh/acme.sh --install-cert -d ${LE_API} -d *.${LE_WILDCARD} --cert-file ${CERT_DIR}/cert.pem --key-file ${CERT_DIR}/key.pem --fullchain-file ${CERT_DIR}/fullchain.pem --ca-file ${CERT_DIR}/ca.cer

oc create secret tls router-certs --cert=${CERT_DIR}/fullchain.pem --key=${CERT_DIR}/key.pem -n openshift-ingress
oc patch ingresscontroller default -n openshift-ingress-operator --type=merge --patch='{"spec": { "defaultCertificate": { "name": "router-certs" }}}'

oc create secret tls api-certs --cert=${CERT_DIR}/fullchain.pem --key=${CERT_DIR}/key.pem -n openshift-config
oc patch apiserver cluster --type merge --patch="{\"spec\": {\"servingCerts\": {\"namedCertificates\": [ { \"names\": [  \"$LE_API\"  ], \"servingCertificate\": {\"name\": \"api-certs\" }}]}}}"

timeout_seconds=1200
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

    sleep 30

done

if [ $SECONDS -ge $end_time ]; then
    echo "Timeout reached. Certificate is still not trusted after $timeout_seconds seconds."
fi