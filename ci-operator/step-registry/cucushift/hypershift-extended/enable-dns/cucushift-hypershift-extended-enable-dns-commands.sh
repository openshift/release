#!/bin/bash
set -e
set -u
set -o pipefail
set -x

if [[ ${DYNAMIC_DNS_ENABLED} == "false" ]]; then
  echo "SKIP ....."
  exit 0
fi

#Get controlplane endpoint
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
    echo "INFO: KubeAPI Server DNS name not configured for '${CLUSTER_NAME}'" >&2
    exit 0
fi
CP_EP=$(oc get hostedclusters/${CLUSTER_NAME} -n "$HYPERSHIFT_NAMESPACE" -o jsonpath='{.status.controlPlaneEndpoint.host}')

#Update route53 record value
export AWS_SHARED_CREDENTIALS_FILE="${CLUSTER_PROFILE_DIR}/.awscred"

HOSTED_ZONE_ID=$(aws route53 list-hosted-zones --query "HostedZones[?Name=='${BASE_DOMAIN}.'].Id" --output text | cut -d'/' -f3)
if [ -z "${HOSTED_ZONE_ID}" ]; then
  echo "hosted zone id does not exist."
  exit 1
fi

RECORD_NAME="${KAS_DNS_NAME}."
EXISTING_TTL=$(aws route53 list-resource-record-sets --hosted-zone-id $HOSTED_ZONE_ID \
  --query "ResourceRecordSets[?Name=='${RECORD_NAME}' && Type=='CNAME'].TTL" \
  --output text)
if [ -z "$EXISTING_TTL" ]; then
   echo "Cannot find valid ttl"
   exit 1
fi
tempfile=$(mktemp)
cat << EOF > ${tempfile}
{
  "Changes": [
    {
      "Action": "UPSERT",
      "ResourceRecordSet": {
        "Name": "${RECORD_NAME}",
        "Type": "CNAME",
        "TTL": ${EXISTING_TTL},
        "ResourceRecords": [
          {
            "Value": "${CP_EP}"
          }
        ]
      }
    }
  ]
}
EOF

echo "Updating..."
if aws route53 change-resource-record-sets \
  --hosted-zone-id "${HOSTED_ZONE_ID}" \
  --change-batch "file://${tempfile}" >/dev/null 2>&1; then
  echo "Record upated successed"
else
  echo "Record upated failed" >&2
  exit 1
fi
id=$(aws route53 change-resource-record-sets --hosted-zone-id "${HOSTED_ZONE_ID}" --change-batch "file://${tempfile}" --query '"ChangeInfo"."Id"' --output text)

echo "Waiting for DNS records to sync..."
aws route53 wait resource-record-sets-changed --id "${id}"

# Clear temp file
rm -rf "${tempfile}"

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
                             "$KAS_DNS_NAME"
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
if ! oc patch hc/$CLUSTER_NAME  -n $HYPERSHIFT_NAMESPACE --type=merge -p "$JSON_PATCH" --request-timeout=2m; then
  echo "Failed to apply the patch to configure HC"
  exit 1
else
  echo "Apply the patch to configure HC successfully"
fi

oc wait deployment kube-apiserver -n "clusters-${CLUSTER_NAME}" --for='condition=PROGRESSING=True' --timeout=2m
oc rollout status deployment -n "clusters-${CLUSTER_NAME}" kube-apiserver --timeout=3m

 echo "Check hc cluster can be visited via custom kubeconfig"
#Check secret with custom-kubeconfig generated in HC anc HCP namespaces
if ! oc get -n "${HYPERSHIFT_NAMESPACE}" secret "${CLUSTER_NAME}-custom-admin-kubeconfig" &>/dev/null; then
    echo "ERROR: Missing required secret '${CLUSTER_NAME}-custom-admin-kubeconfig' in HC namespace '${HYPERSHIFT_NAMESPACE}'" >&2
    exit 1
fi

if ! oc get -n "clusters-${CLUSTER_NAME}" secret custom-admin-kubeconfig &>/dev/null; then
    echo "ERROR: Missing required secret 'custom-admin-kubeconfig' in HCP namespace 'clusters-${CLUSTER_NAME}'" >&2
    exit 1
fi

echo "Cluster secrets validation passed"

#Visit hc with custom kubeconfig
CUSTOM_KUBECONFIG=/tmp/custom_kube
oc get -n "$HYPERSHIFT_NAMESPACE" secret "${CLUSTER_NAME}-custom-admin-kubeconfig" -o jsonpath='{.data.kubeconfig}' | base64 -d > $CUSTOM_KUBECONFIG || exit 1

oc --kubeconfig $CUSTOM_KUBECONFIG get clusterversion version &>/dev/null || {
    echo "ERROR: Cluster API unreachable with kubeconfig: $CUSTOM_KUBECONFIG" >&2
    exit 1
}
echo "Cluster API endpoint reachable with custom kubeconfig"

rm -rf /tmp/custom_kube
