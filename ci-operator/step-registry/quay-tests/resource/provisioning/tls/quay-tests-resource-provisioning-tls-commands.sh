#!/bin/bash

set -o nounset
set -o errexit
set -o pipefail

#Create TLS Cert/Key pairs for Quay Deployment
QUAYREGISTRY=${QUAYREGISTRY}
QUAYNAMESPACE=${QUAYNAMESPACE}

echo "Create TLS Cert/Key pairs for Quay Deployment..." >&2

ocp_base_domain_name=$(oc get dns/cluster -o jsonpath="{.spec.baseDomain}")

#In Prow, base domain is longer, like: ci-op-w3ki37mj-cc978.qe.devcluster.openshift.com
#it's easy to meet below maxsize error if len(quay_cn_name)>64
#encoding routines:ASN1_mbstring_ncopy:string too long:crypto/asn1/a_mbstr.c:107:maxsize=64
quay_cn_wildcard_name="apps."$ocp_base_domain_name
quay_cn_name="quay.${quay_cn_wildcard_name}"
quay_builder_route="${QUAYREGISTRY}-quay-builder-${QUAYNAMESPACE}.${quay_cn_wildcard_name}"
quay_name="${QUAYREGISTRY}-quay-${QUAYNAMESPACE}.${quay_cn_wildcard_name}"

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
DNS.1 = ${quay_cn_name}
DNS.2 = ${quay_builder_route}
DNS.3 = ${quay_name}
EOF

#Create custom tls/ssl file
function create_cert() {
    openssl genrsa -out "$temp_dir"/rootCA.key 2048
    openssl req -x509 -new -nodes -key "$temp_dir"/rootCA.key -sha256 -days 1024 -out "$temp_dir"/rootCA.pem -subj "/C=CN/ST=Beijing/L=BJ/O=Quay team/OU=Quay QE Team/CN=${quay_cn_wildcard_name}"
    openssl genrsa -out "$temp_dir"/ssl.key 2048
    openssl req -new -key "$temp_dir"/ssl.key -out "$temp_dir"/ssl.csr -subj "/C=CN/ST=Beijing/L=BJ/O=Quay team/OU=Quay QE Team/CN=${quay_cn_name}"
    openssl x509 -req -in "$temp_dir"/ssl.csr -CA "$temp_dir"/rootCA.pem -CAkey "$temp_dir"/rootCA.key -CAcreateserial -out "$temp_dir"/ssl.cert -days 356 -extensions v3_req -extfile "$temp_dir"/openssl.cnf
    cat "$temp_dir"/rootCA.pem >>"$temp_dir"/ssl.cert

    if [ -e "$temp_dir"/ssl.cert ]; then
        echo "Create the TLS/SSL cert file successfully"
    else
        echo "!!! Fail to create the TLS/SSL cert file "
        return 1
    fi

}

#Create Artifact Directory
ARTIFACT_DIR=${ARTIFACT_DIR:=/tmp/artifacts}
mkdir -p "$ARTIFACT_DIR"

function copyCerts {
    #Copy ssl files to SHARED_DIR
    echo "Copy tls certs to $SHARED_DIR folder"
    mv ca.crt "$SHARED_DIR"/build_cluster.crt
    cp "$temp_dir"/ssl.cert "$temp_dir"/ssl.key "$SHARED_DIR"

    #Archive the tls cert files
    cp "$temp_dir"/ssl.cert "$temp_dir"/ssl.key "$ARTIFACT_DIR"

    #Clean up temp dir
    rm -rf "$temp_dir" || true
}

#Get openshift CA Cert, include into secret bundle
oc extract cm/kube-root-ca.crt -n openshift-apiserver --confirm
create_cert || true
echo "tls cert successfully created"

#Finally Copy certs to SHARED_DIR and archive them
trap copyCerts EXIT
