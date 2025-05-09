#!/bin/bash

set -o nounset
set -o errexit
set -o pipefail

#Create TLS Cert/Key pairs for HC kas
if [ ! -f "${SHARED_DIR}/kubeconfig" ]; then
    exit 1
fi
export KUBECONFIG="${SHARED_DIR}/kubeconfig"
if [[ -f "${SHARED_DIR}/proxy-conf.sh" ]]; then
    source "${SHARED_DIR}/proxy-conf.sh"
fi

CLUSTER_NAME=$(oc get hostedclusters -n "$HYPERSHIFT_NAMESPACE" -o jsonpath='{.items[0].metadata.name}')
echo "hostedclusters => ns: $HYPERSHIFT_NAMESPACE , cluster_name: $CLUSTER_NAME"
if ! KAS_DNS_NAME=$(oc get "hostedclusters/${CLUSTER_NAME}" -n "${HYPERSHIFT_NAMESPACE}" \
    -o jsonpath='{.spec.kubeAPIServerDNSName}' 2>/dev/null)
then
    echo "ERROR: HostedCluster '${CLUSTER_NAME}' not found in namespace '${HYPERSHIFT_NAMESPACE}'" >&2
    exit 1
elif [[ -z "${KAS_DNS_NAME}" ]]; then
    echo "ERROR: KubeAPI Server DNS name not configured for '${CLUSTER_NAME}'" >&2
    exit 1
fi

echo "Create TLS Cert/Key pairs for kas..." >&2
temp_dir=$(mktemp -d)

cat >>"$temp_dir"/openssl.cnf <<EOF
[req]
req_extensions = v3_req
distinguished_name = req_distinguished_name
[req_distinguished_name]
[ v3_req ]
basicConstraints = CA:FALSE
keyUsage = nonRepudiation, digitalSignature, keyEncipherment
extendedKeyUsage = clientAuth, serverAuth
subjectAltName = @alt_names
[alt_names]
DNS.1 = ${KAS_DNS_NAME}
EOF

openssl genrsa -out "$temp_dir"/caKey.pem 2048 2>/dev/null
openssl req  -sha256 -x509 -new -nodes -key "$temp_dir"/caKey.pem -days 100000 -out "$temp_dir"/caCert.pem -subj "/CN=${KAS_DNS_NAME}_ca" 2>/dev/null
openssl genrsa -out "$temp_dir"/serverKey.pem 2048 2>/dev/null
openssl req -sha256 -new -key "$temp_dir"/serverKey.pem -out "$temp_dir"/server.csr -subj "/CN=${KAS_DNS_NAME}_server" -config "$temp_dir"/openssl.cnf 2>/dev/null
openssl x509 -sha256 -req -in "$temp_dir"/server.csr -CA "$temp_dir"/caCert.pem -CAkey "$temp_dir"/caKey.pem -CAcreateserial -out "$temp_dir"/serverCert.pem -days 100000 -extensions v3_req -extfile "$temp_dir"/openssl.cnf 2>/dev/null

if [ -e "$temp_dir"/serverKey.pem ]; then
    echo "Create the TLS/SSL key file successfully"
else
    echo "!!! Fail to create the TLS/SSL key file "
    return 1
fi

if [ -e "$temp_dir"/serverCert.pem ]; then
    echo "Create the TLS/SSL cert file successfully"
else
    echo "!!! Fail to create the TLS/SSL cert file "
    return 1
fi

echo "Add the certificate and key to the Secret"
    # if ! oc get secret custom-cert-kas -n "${HYPERSHIFT_NAMESPACE}" 2>/dev/null; then
    #     oc create secret generic custom-cert-kas \
    #         --namespace="${HYPERSHIFT_NAMESPACE}" \
    #         --from-file=tls.key="$temp_dir"/serverKey.pem \
    #         --from-file=tls.crt="$temp_dir"/serverCert.pem \
    #         --request-timeout=10s
    # fi
sleep 6h 
if ! oc get secret custom-cert-kas -n "${HYPERSHIFT_NAMESPACE}" 2>/dev/null; then
    oc create secret tls custom-cert-kas \
        --namespace="${HYPERSHIFT_NAMESPACE}" \
        --key="$temp_dir"/serverKey.pem \
        --cert="$temp_dir"/serverCert.pem \
        --request-timeout=10s
fi

#Clean up temp dir
rm -rf "$temp_dir" || true

# Config hostedCluster.spec.configuration.apiServer.ServingCerts.namedCertificates 
JSON_PATCH=$(cat <<EOF
{
   "spec": {
        "configuration": {
            "apiServer": {
                "servingCerts": {
                    "namedCertificates": [
                    {
                        "names": [
                            "${KAS_DNS_NAME}"
                        ],
                        "servingCertificate": {
                            "name": "custom-cert-kas"
                        }
                    }
                ]
            }
        }
    }
  }
}
EOF
)
if ! oc patch hc/$CLUSTER_NAME  -n $HYPERSHIFT_NAMESPACE --type=merge -p "$JSON_PATCH"; then
  echo "Failed to apply the patch to configure HC"
  exit 1
else
  echo "Apply the patch to configure HC successfully"
fi
 sleep 60