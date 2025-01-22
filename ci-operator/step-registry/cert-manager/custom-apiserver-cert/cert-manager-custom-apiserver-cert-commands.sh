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
}

function check_clusterissuer() {
    echo "Checking the persence of ClusterIssuer '$CLUSTERISSUER_NAME' as prerequisite..."
    if ! oc wait clusterissuer/$CLUSTERISSUER_NAME --for=condition=Ready --timeout=0; then
        echo "ClusterIssuer is not created or not ready to use. Skipping rest of steps..."
        exit 0
    fi
}

function configure_alt_apiserver_endpoint() {
    echo "Creating a LoadBalancer service for the alternative API Server endpoint..."
    # API Server uses port 6443 in convention. Thus we configure "port: 6443" for the alternative API Server FQDN (NEW_API_FQDN) as well.
    oc apply -f - << EOF
apiVersion: v1
kind: Service
metadata:
  name: alt-apiserver-endpoint
  namespace: openshift-kube-apiserver
spec:
  ports:
    - name: https
      port: 6443
      protocol: TCP
      targetPort: 6443
  selector:
    apiserver: "true"
  type: LoadBalancer
EOF

    echo "Retrieving the created LoadBalancer ingress's Hostname or IP..."
    for _ in {1..30}; do
        EXTERNAL_IP=$(oc get service alt-apiserver-endpoint -n openshift-kube-apiserver -o=jsonpath='{.status.loadBalancer.ingress[0].hostname}')
        if [[ -n "${EXTERNAL_IP}" ]]; then
            RECORD_TYPE=CNAME
            break
        fi

        EXTERNAL_IP=$(oc get service alt-apiserver-endpoint -n openshift-kube-apiserver -o=jsonpath='{.status.loadBalancer.ingress[0].ip}')
        if [[ -n "${EXTERNAL_IP}" ]]; then
            RECORD_TYPE=A
            break
        fi

        sleep 5
    done
    if [[ -z "${EXTERNAL_IP}" ]]; then
        echo "Timed out wait for Hostname or IP to be created. Skipping rest of steps..."
        exit 0
    fi

    echo "Creating DNSRecord for the alternative API Server endpoint..."
    oc apply -f - << EOF
apiVersion: ingress.operator.openshift.io/v1
kind: DNSRecord
metadata:
  name: alt-apiserver-endpoint
  namespace: openshift-ingress-operator
spec:
  dnsManagementPolicy: Managed
  dnsName: "${NEW_API_FQDN}."
  recordTTL: 30
  recordType: $RECORD_TYPE
  targets:
  - ${EXTERNAL_IP}
EOF

    echo "Waiting for the DNSRecord to become Published..."
    oc wait dnsrecord alt-apiserver-endpoint -n openshift-ingress-operator --for=jsonpath='{.status.zones[0].conditions[?(@.type=="Published")].status}'=True --timeout=2m
}

function create_apiserver_certificate() {
    oc apply -f - << EOF
apiVersion: cert-manager.io/v1
kind: Certificate
metadata:
  name: $CERT_NAME
  namespace: $CERT_NAMESPACE
spec:
  commonName: "$NEW_API_FQDN"
  dnsNames:
  - "$NEW_API_FQDN"
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

function configure_apiserver_default_cert() {
    echo "Patching the issued TLS secret to API Server's spec..."
    local json_path='{"spec":{"servingCerts": {"namedCertificates": [{"names": ["'"$NEW_API_FQDN"'"], "servingCertificate": {"name": "'"$CERT_SECRET_NAME"'"}}]}}}' 
    oc patch apiserver cluster --type=merge -p "$json_path"

    echo "[$(timestamp)] Waiting for the Kube API Server ClusterOperator to finish rollout..."
    oc wait co kube-apiserver --for=condition=Progressing=True --timeout=5m
    oc wait co kube-apiserver --for=condition=Progressing=False --timeout=20m
    echo "[$(timestamp)] Rollout progress completed"
}

function extract_ca_from_secret() {
    echo "Extracting the CA certificate from the issued TLS secret to local folder..."
    oc extract secret/"$CERT_SECRET_NAME" -n $CERT_NAMESPACE
    CA_FILE=$( [ -f ca.crt ] && echo "ca.crt" || echo "tls.crt" )
}

function validate_serving_cert() {
    echo "Validating the serving certificate of '$NEW_API_URL'..."
    output=$(curl -I -v --cacert $CA_FILE --connect-timeout 30 "$NEW_API_FQDN" 2>&1)
    if [ $? -eq 0 ]; then
        echo "The certificate is served by API Server as expected"
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

    echo "Validating the updated KUBECONFIG using any of oc command"
    run_command "oc get pod -n openshift-kube-apiserver -L revision -l apiserver"
}

timestamp
set_proxy
check_clusterissuer

CERT_NAME=custom-apiserver-cert
CERT_NAMESPACE=openshift-config
CERT_SECRET_NAME=cert-manager-managed-apiserver-cert-tls
BASE_DOMAIN=$(oc get dns cluster -o=jsonpath='{.spec.baseDomain}')
NEW_API_FQDN=alt-api.${BASE_DOMAIN}
NEW_API_URL=https://${NEW_API_FQDN}:6443

configure_alt_apiserver_endpoint
create_apiserver_certificate
configure_apiserver_default_cert

TMP_DIR=/tmp/cert-manager-custom-apiserver-cert
mkdir -p "$TMP_DIR"
cd "$TMP_DIR"

extract_ca_from_secret
validate_serving_cert
update_kubeconfig_ca

echo "[$(timestamp)] Succeeded in adding cert-manager managed certificates to the alternative API Server as named certificate!"
