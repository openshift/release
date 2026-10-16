#!/bin/bash
set -euo pipefail

# Tracing stays off throughout: proxy-conf.sh exports HTTP_PROXY with embedded
# credentials, and the kubeconfig/certificate handling below is equally sensitive.

if [[ ! -f "${SHARED_DIR}/kubeconfig" ]]; then
  echo "ERROR: ${SHARED_DIR}/kubeconfig not found"
  exit 1
fi
export KUBECONFIG="${SHARED_DIR}/kubeconfig"

if [[ -f "${SHARED_DIR}/proxy-conf.sh" ]]; then
  source "${SHARED_DIR}/proxy-conf.sh"
fi

# hypershift-aws-create records the name it used; only fall back to listing when the
# step runs in a context that did not go through that chain.
if [[ -s "${SHARED_DIR}/cluster-name" ]]; then
  CLUSTER_NAME=$(cat "${SHARED_DIR}/cluster-name")
else
  CLUSTER_NAME=$(oc get hostedclusters -n "${HYPERSHIFT_NAMESPACE}" -o jsonpath='{.items[0].metadata.name}')
fi
if [[ -z "${CLUSTER_NAME}" ]]; then
  echo "ERROR: no HostedCluster found in namespace ${HYPERSHIFT_NAMESPACE}" >&2
  exit 1
fi
HCP_NAMESPACE="${HYPERSHIFT_NAMESPACE}-${CLUSTER_NAME}"
echo "HostedCluster ${HYPERSHIFT_NAMESPACE}/${CLUSTER_NAME}"

# hypershift-aws-create records the name it passed to --kas-dns-name; the HostedCluster
# spec is the fallback so the step also works when the name was set by other means.
if [[ -s "${SHARED_DIR}/kas_dns_name" ]]; then
  KAS_DNS_NAME=$(cat "${SHARED_DIR}/kas_dns_name")
else
  KAS_DNS_NAME=$(oc get "hostedclusters/${CLUSTER_NAME}" -n "${HYPERSHIFT_NAMESPACE}" \
    -o jsonpath='{.spec.kubeAPIServerDNSName}')
fi
if [[ -z "${KAS_DNS_NAME}" ]]; then
  echo "ERROR: no kube-apiserver DNS name configured for ${CLUSTER_NAME}" >&2
  exit 1
fi
echo "KAS DNS name: ${KAS_DNS_NAME}"

SPEC_DNS_NAME=$(oc get "hostedclusters/${CLUSTER_NAME}" -n "${HYPERSHIFT_NAMESPACE}" \
  -o jsonpath='{.spec.kubeAPIServerDNSName}')
if [[ "${SPEC_DNS_NAME}" != "${KAS_DNS_NAME}" ]]; then
  echo "ERROR: HostedCluster spec.kubeAPIServerDNSName is '${SPEC_DNS_NAME}', expected '${KAS_DNS_NAME}'" >&2
  exit 1
fi

CP_EP=$(oc get "hostedclusters/${CLUSTER_NAME}" -n "${HYPERSHIFT_NAMESPACE}" \
  -o jsonpath='{.status.controlPlaneEndpoint.host}')
if [[ -z "${CP_EP}" ]]; then
  echo "ERROR: control plane endpoint is not yet populated for ${CLUSTER_NAME}" >&2
  exit 1
fi
echo "Control plane endpoint: ${CP_EP}"

export AWS_SHARED_CREDENTIALS_FILE="${CLUSTER_PROFILE_DIR}/.awscred"

# Everything after the first label of the KAS DNS name is the zone we write into.
ZONE_DOMAIN="${HYPERSHIFT_DYNAMIC_DNS_BASE_DOMAIN:-${KAS_DNS_NAME#*.}}"
HOSTED_ZONE_ID=$(aws route53 list-hosted-zones \
  --query "HostedZones[?Name=='${ZONE_DOMAIN}.'].[Id,Config.PrivateZone]" --output text \
  | awk '$2 == "False" { print $1; exit }' | cut -d'/' -f3)
if [[ -z "${HOSTED_ZONE_ID}" ]]; then
  echo "ERROR: no public Route53 hosted zone found for ${ZONE_DOMAIN}" >&2
  exit 1
fi
echo "Route53 hosted zone: ${HOSTED_ZONE_ID}"

# UPSERT creates the record when it is absent, which is what makes a per-run unique
# DNS name possible: nothing has to be pre-provisioned in the zone.
record_set=$(cat <<EOF
{
  "Name": "${KAS_DNS_NAME}.",
  "Type": "CNAME",
  "TTL": ${KAS_DNS_TTL},
  "ResourceRecords": [ { "Value": "${CP_EP}" } ]
}
EOF
)

# Hand the exact record set to hypershift-aws-kas-dns-cleanup: a Route53 DELETE has to
# describe the record set exactly as it was created, and reconstructing it from a query
# in post is both fragile and needless when we already know every field here.
echo "${HOSTED_ZONE_ID}" > "${SHARED_DIR}/kas_dns_zone_id"
cat > "${SHARED_DIR}/kas_dns_delete_batch.json" <<EOF
{ "Changes": [ { "Action": "DELETE", "ResourceRecordSet": ${record_set} } ] }
EOF

changebatch=$(mktemp)
cat > "${changebatch}" <<EOF
{ "Changes": [ { "Action": "UPSERT", "ResourceRecordSet": ${record_set} } ] }
EOF

echo "Pointing ${KAS_DNS_NAME} at ${CP_EP}..."
change_id=$(aws route53 change-resource-record-sets \
  --hosted-zone-id "${HOSTED_ZONE_ID}" \
  --change-batch "file://${changebatch}" \
  --query 'ChangeInfo.Id' --output text)
rm -f "${changebatch}"

echo "Waiting for Route53 to propagate the record (change ${change_id})..."
aws route53 wait resource-record-sets-changed --id "${change_id}"

# Route53 reporting INSYNC only means its own name servers agree; the resolver this pod
# uses still has to pick the record up. Wait for that explicitly so a resolution problem
# is reported as such instead of surfacing later as an opaque connection failure.
if [[ -n "${HTTPS_PROXY:-}" || -n "${https_proxy:-}" ]]; then
  # Behind a proxy the name is resolved by the proxy, not by this pod, so a local lookup
  # proves nothing. The reachability check below covers it either way.
  echo "A proxy is configured, skipping the local resolution check for ${KAS_DNS_NAME}"
else
  echo "Waiting for ${KAS_DNS_NAME} to resolve..."
  deadline=$(( $(date +%s) + DNS_RESOLUTION_TIMEOUT ))
  until getent hosts "${KAS_DNS_NAME}" >/dev/null; do
    if [[ $(date +%s) -ge ${deadline} ]]; then
      echo "ERROR: ${KAS_DNS_NAME} did not resolve within ${DNS_RESOLUTION_TIMEOUT}s" >&2
      exit 1
    fi
    sleep 10
  done
  echo "${KAS_DNS_NAME} resolves"
fi

# The certificate is self-signed rather than signed by a throwaway CA, matching what the
# HyperShift e2e suite generates. HyperShift builds the custom kubeconfig's CA bundle by
# concatenating the cluster root CA with the raw tls.crt of every named certificate, so
# tls.crt has to be usable as a trust anchor on its own.
echo "Creating a self-signed serving certificate for ${KAS_DNS_NAME}..."
temp_dir=$(mktemp -d)
cat > "${temp_dir}/openssl.cnf" <<EOF
[req]
distinguished_name = req_distinguished_name
[req_distinguished_name]
[v3_req]
basicConstraints = CA:FALSE
keyUsage = digitalSignature, keyEncipherment
extendedKeyUsage = serverAuth
subjectAltName = @alt_names
[alt_names]
DNS.1 = ${KAS_DNS_NAME}
EOF

openssl req -x509 -sha256 -nodes -newkey rsa:2048 -days 30 \
  -keyout "${temp_dir}/serverKey.pem" -out "${temp_dir}/serverCert.pem" \
  -subj "/CN=${KAS_DNS_NAME}/O=kubernetes/OU=openshift-release-ci" \
  -config "${temp_dir}/openssl.cnf" -extensions v3_req
openssl x509 -in "${temp_dir}/serverCert.pem" -noout -subject -dates
# Guard against an openssl build silently ignoring -extensions: without the SAN the
# kube-apiserver would keep serving its default certificate for this hostname.
if ! openssl x509 -in "${temp_dir}/serverCert.pem" -noout -text | grep -q "DNS:${KAS_DNS_NAME}"; then
  echo "ERROR: the generated certificate carries no subjectAltName for ${KAS_DNS_NAME}" >&2
  exit 1
fi

oc create secret tls custom-cert-kas \
  --namespace="${HYPERSHIFT_NAMESPACE}" \
  --key="${temp_dir}/serverKey.pem" \
  --cert="${temp_dir}/serverCert.pem" \
  --dry-run=client -o yaml \
  | oc apply -n "${HYPERSHIFT_NAMESPACE}" -f - --request-timeout=30s
rm -rf "${temp_dir}"

kas_generation=$(oc get deployment kube-apiserver -n "${HCP_NAMESPACE}" -o jsonpath='{.metadata.generation}')

echo "Configuring spec.configuration.apiServer.servingCerts.namedCertificates..."
oc patch "hc/${CLUSTER_NAME}" -n "${HYPERSHIFT_NAMESPACE}" --type=merge --request-timeout=2m -p "$(cat <<EOF
{
  "spec": {
    "configuration": {
      "apiServer": {
        "servingCerts": {
          "namedCertificates": [
            {
              "names": [ "${KAS_DNS_NAME}" ],
              "servingCertificate": { "name": "custom-cert-kas" }
            }
          ]
        }
      }
    }
  }
}
EOF
)"

# Wait for the control plane operator to roll the named certificate out. Waiting on
# condition=Progressing is useless here - a healthy Deployment already reports it as True
# - so watch for the generation bump the new kube-apiserver config produces instead.
echo "Waiting for the kube-apiserver to pick up the named certificate..."
deadline=$(( $(date +%s) + KAS_ROLLOUT_TIMEOUT ))
while [[ $(oc get deployment kube-apiserver -n "${HCP_NAMESPACE}" -o jsonpath='{.metadata.generation}') -le ${kas_generation} ]]; do
  if [[ $(date +%s) -ge ${deadline} ]]; then
    echo "WARNING: the kube-apiserver deployment was not updated within ${KAS_ROLLOUT_TIMEOUT}s" >&2
    break
  fi
  sleep 10
done
oc rollout status deployment/kube-apiserver -n "${HCP_NAMESPACE}" --timeout="${KAS_ROLLOUT_TIMEOUT}s"

echo "Verifying the generated custom admin kubeconfig..."
for ns_secret in "${HYPERSHIFT_NAMESPACE}/${CLUSTER_NAME}-custom-admin-kubeconfig" \
                 "${HCP_NAMESPACE}/custom-admin-kubeconfig"; do
  # Both are created at day-1 because kubeAPIServerDNSName is set at cluster creation,
  # but give the control plane operator room to catch up rather than failing instantly.
  deadline=$(( $(date +%s) + 300 ))
  until oc get -n "${ns_secret%%/*}" secret "${ns_secret##*/}" >/dev/null 2>&1; do
    if [[ $(date +%s) -ge ${deadline} ]]; then
      echo "ERROR: secret ${ns_secret} was never created" >&2
      exit 1
    fi
    sleep 10
  done
done

custom_kubeconfig=$(mktemp)
trap 'rm -f "${custom_kubeconfig}"' EXIT

# The secret is re-read on every attempt on purpose. HyperShift regenerates it with a CA
# bundle that includes the named certificate only after the patch above is reconciled, so
# a copy taken once up front stays pinned to the pre-patch bundle and can never validate.
deadline=$(( $(date +%s) + KAS_REACHABILITY_TIMEOUT ))
attempt=0
while true; do
  attempt=$(( attempt + 1 ))
  if ! kubeconfig_data=$(oc get -n "${HYPERSHIFT_NAMESPACE}" secret "${CLUSTER_NAME}-custom-admin-kubeconfig" \
       -o jsonpath='{.data.kubeconfig}' 2>&1); then
    err="failed to read the custom admin kubeconfig secret: ${kubeconfig_data}"
  elif ! base64 -d <<<"${kubeconfig_data}" > "${custom_kubeconfig}" 2>/dev/null; then
    err="the custom admin kubeconfig secret does not hold decodable kubeconfig data"
  elif err=$(oc --kubeconfig "${custom_kubeconfig}" get clusterversion version 2>&1); then
    echo "Cluster API endpoint reachable at ${KAS_DNS_NAME} with the custom kubeconfig"
    break
  fi

  if [[ $(date +%s) -ge ${deadline} ]]; then
    echo "ERROR: ${KAS_DNS_NAME} did not become reachable with the custom kubeconfig within ${KAS_REACHABILITY_TIMEOUT}s" >&2
    echo "ERROR: last failure was: ${err}" >&2
    exit 1
  fi
  if [[ $(( attempt % 4 )) -eq 1 ]]; then
    echo "attempt ${attempt}: ${err}"
  fi
  sleep 15
done
