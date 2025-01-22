#!/bin/bash

set -e
set -u
set -o pipefail

function timestamp() {
    date -u --rfc-3339=seconds
}

function run_command() {
    local cmd="$1"
    echo "Running Command: ${cmd}"
    eval "${cmd}"
}

function set_proxy () {
    if test -s "${SHARED_DIR}/proxy-conf.sh" ; then
        echo "Setting proxy configuration..."
        source "${SHARED_DIR}/proxy-conf.sh"
    else
        echo "No proxy settings found. Skipping proxy configuration..."
    fi
}

function wait_for_state() {
    local object="$1"
    local state="$2"
    local timeout="$3"
    local namespace="${4:-}"
    local selector="${5:-}"

    echo "Waiting for '${object}' in namespace '${namespace}' with selector '${selector}' to exist..."
    for _ in {1..30}; do
        oc get ${object} --selector="${selector}" -n=${namespace} |& grep -ivE "(no resources found|not found)" && break || sleep 5
    done

    echo "Waiting for '${object}' in namespace '${namespace}' with selector '${selector}' to become '${state}'..."
    oc wait --for=${state} --timeout=${timeout} ${object} --selector="${selector}" -n="${namespace}"
    return $?
}

function check_clusterissuer() {
    echo "Checking the persence of ClusterIssuer '$CLUSTERISSUER_NAME' as prerequisite..."
    if ! oc wait clusterissuer/$CLUSTERISSUER_NAME --for=condition=Ready --timeout=0; then
        echo "ClusterIssuer is not created or not ready to use. Skipping rest of steps..."
        exit 0
    fi
}

function create_ingress_certificate () {
    echo "Creating the wildcard certificate for the Ingress Controller..."
    oc apply -f - << EOF
apiVersion: cert-manager.io/v1
kind: Certificate
metadata:
  name: $CERT_NAME
  namespace: $CERT_NAMESPACE
spec:
  commonName: "*.${INGRESS_DOMAIN}"
  dnsNames:
  - "*.${INGRESS_DOMAIN}"
  usages:
  - server auth
  issuerRef:
    kind: ClusterIssuer
    name: $CLUSTERISSUER_NAME
  secretName: $CERT_SECRET_NAME
  privateKey:
    rotationPolicy: Always
  duration: 2h
  renewBefore: 1h30m
EOF

    if wait_for_state "certificate/$CERT_NAME" "condition=Ready" "5m" "$CERT_NAMESPACE"; then
        echo "Certificate is ready"
    else
        echo "Timed out after 5m. Dumping resources for debugging..."
        run_command "oc describe certificate $CERT_NAME -n $CERT_NAMESPACE"
        exit 1
    fi
}

function configure_ingress_default_cert() {
    echo "Patching the issued TLS secret to Ingress Controller's spec..."
    local json_path='{"spec":{"defaultCertificate": {"name": "'"$CERT_SECRET_NAME"'"}}}'
    oc patch ingresscontroller default --type=merge -p "$json_path" -n openshift-ingress-operator

    echo "[$(timestamp)] Waiting for the Ingress ClusterOperator to finish rollout..."
    oc wait co ingress --for=condition=Progressing=True --timeout=2m
    oc wait co ingress --for=condition=Progressing=False --timeout=5m
    echo "[$(timestamp)] Rollout progress completed"
}

function extract_ca_from_secret() {
    echo "Extracting the CA certificate from the issued TLS secret to local folder..."
    oc extract secret/"$CERT_SECRET_NAME" -n $CERT_NAMESPACE
    CA_FILE=$( [ -f ca.crt ] && echo "ca.crt" || echo "tls.crt" )
}

function validate_serving_cert() {
    echo "Validating the serving certificate of '$CONSOLE_URL'..."
    output=$(curl -I -v --cacert $CA_FILE --connect-timeout 30 "$CONSOLE_URL" 2>&1)
    if [ $? -eq 0 ]; then
        echo "The certificate is served by Ingress Controller as expected"
    else
        echo "Failed curl validation. Curl output: '$output'"
        exit 1
    fi
}

function update_kubeconfig_ca() {
    echo "Backing up the old KUBECONFIG file..."
    run_command "cp -f $KUBECONFIG $KUBECONFIG.old"

    echo "Appending the CA data of KUBECONFIG with the new CA certificate..."
    CA_DATA=$(grep certificate-authority-data "$KUBECONFIG".old | awk '{print $2}' | base64 -d)
    cat "$CA_FILE" >> <(echo "$CA_DATA")
    NEW_CA_DATA=$(echo "$CA_DATA" | base64 -w0)
    sed -i "s/certificate-authority-data:.*$/certificate-authority-data: $NEW_CA_DATA/" "$KUBECONFIG"

    echo "Validating the updated KUBECONFIG using any of oc command..."
    run_command "oc get node"
}

timestamp
set_proxy
check_clusterissuer

CERT_NAME=custom-ingress-cert
CERT_NAMESPACE=openshift-ingress
CERT_SECRET_NAME=cert-manager-managed-ingress-cert-tls
INGRESS_DOMAIN=$(oc get ingress.config cluster -o=jsonpath='{.spec.domain}')
CONSOLE_URL=$(oc whoami --show-console)

create_ingress_certificate
configure_ingress_default_cert

TMP_DIR=/tmp/cert-manager-custom-ingress-cert
mkdir -p "$TMP_DIR"
cd "$TMP_DIR"

extract_ca_from_secret
validate_serving_cert
update_kubeconfig_ca

echo "[$(timestamp)] Succeeded in replacing the default Ingress Controller serving certificates with cert-manager managed ones!"
