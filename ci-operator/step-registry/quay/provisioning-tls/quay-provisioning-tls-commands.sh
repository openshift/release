#!/bin/bash

set -o nounset
set -o errexit
set -o pipefail

#Create TLS Cert/Key pairs for Quay Deployment
QUAYREGISTRY=${QUAYREGISTRY}
QUAYNAMESPACE=${QUAYNAMESPACE}

echo "Create TLS Cert/Key pairs for Quay Deployment..." >&2

ocp_base_domain_name=$(oc get dns/cluster -o jsonpath="{.spec.baseDomain}")

# In Prow, the base domain can be long enough that putting a route name in a
# subject CN exceeds OpenSSL's 64-character CN limit. Keep the subject short;
# the complete route names belong in SANs.
quay_cn_wildcard_name="apps."$ocp_base_domain_name
quay_tls_common_name="quay"
quay_route_name="quay.${quay_cn_wildcard_name}"
quay_builder_route="${QUAYREGISTRY}-quay-builder-${QUAYNAMESPACE}.${quay_cn_wildcard_name}"
quay_name="${QUAYREGISTRY}-quay-${QUAYNAMESPACE}.${quay_cn_wildcard_name}"

temp_dir=$(mktemp -d)
function cleanup() {
    rm -rf "$temp_dir"
}
trap cleanup EXIT

cat >"$temp_dir"/openssl.cnf <<EOF
[req]
req_extensions = v3_req
distinguished_name = req_distinguished_name
[req_distinguished_name]
[ v3_req ]
basicConstraints = CA:FALSE
keyUsage = nonRepudiation, digitalSignature, keyEncipherment
subjectAltName = @alt_names
[alt_names]
DNS.1 = ${quay_route_name}
DNS.2 = ${quay_builder_route}
DNS.3 = ${quay_name}
EOF

#Create custom tls/ssl file
function create_cert() {
    openssl genrsa -out "$temp_dir"/rootCA.key 2048
    openssl req -x509 -new -nodes -key "$temp_dir"/rootCA.key -sha256 -days 1024 -out "$temp_dir"/rootCA.pem -subj "/C=US/ST=North Carolina/L=Raleigh/O=Quay team/OU=Quay QE Team/CN=${quay_cn_wildcard_name}"
    openssl genrsa -out "$temp_dir"/ssl.key 2048
    openssl req -new -key "$temp_dir"/ssl.key -out "$temp_dir"/ssl.csr -subj "/C=US/ST=North Carolina/L=Raleigh/O=Quay team/OU=Quay QE Team/CN=${quay_tls_common_name}"
    openssl x509 -req -in "$temp_dir"/ssl.csr -CA "$temp_dir"/rootCA.pem -CAkey "$temp_dir"/rootCA.key -CAcreateserial -out "$temp_dir"/ssl.cert -days 356 -extensions v3_req -extfile "$temp_dir"/openssl.cnf
    cat "$temp_dir"/rootCA.pem >>"$temp_dir"/ssl.cert

    if [[ ! -s "$temp_dir"/ssl.cert ]]; then
        echo "Failed to create a non-empty TLS/SSL certificate" >&2
        return 1
    fi
    echo "Created the TLS/SSL certificate"
}

function verify_cert() {
    local cert_key_fingerprint
    local key_fingerprint
    local hostname

    if [[ ! -s "$temp_dir"/ssl.cert || ! -s "$temp_dir"/ssl.key || ! -s "$temp_dir"/rootCA.pem ]]; then
        echo "TLS certificate, key, or CA is missing or empty" >&2
        return 1
    fi

    cert_key_fingerprint=$(openssl x509 -in "$temp_dir"/ssl.cert -noout -modulus | openssl sha256)
    key_fingerprint=$(openssl rsa -in "$temp_dir"/ssl.key -noout -modulus | openssl sha256)
    if [[ "$cert_key_fingerprint" != "$key_fingerprint" ]]; then
        echo "TLS certificate does not match its private key" >&2
        return 1
    fi

    openssl verify -CAfile "$temp_dir"/rootCA.pem "$temp_dir"/ssl.cert
    for hostname in "$quay_route_name" "$quay_builder_route" "$quay_name"; do
        openssl verify -verify_hostname "$hostname" -CAfile "$temp_dir"/rootCA.pem "$temp_dir"/ssl.cert
    done
}

#Create Artifact Directory
ARTIFACT_DIR=${ARTIFACT_DIR:=/tmp/artifacts}
mkdir -p "$ARTIFACT_DIR"

function copy_certs() {
    # Copy deploy inputs to SHARED_DIR.
    echo "Copy tls certs to $SHARED_DIR folder"
    cp "$temp_dir"/ca.crt "$SHARED_DIR"/build_cluster.crt
    cp "$temp_dir"/ssl.cert "$temp_dir"/ssl.key "$SHARED_DIR"

    # ARTIFACT_DIR is public; never archive the TLS private key.
    cp "$temp_dir"/ssl.cert "$ARTIFACT_DIR"
}

# Get the OpenShift CA certificate for the builder configuration.
oc extract cm/kube-root-ca.crt -n openshift-apiserver --to="$temp_dir" --confirm
create_cert
verify_cert
copy_certs

echo "TLS certificate successfully created and verified"
