#!/bin/bash

set -o nounset
set -o errexit
set -o pipefail

#Create TLS Cert/Key pairs for Quay Deployment
QUAYREGISTRY=${QUAYREGISTRY}
NAMESPACE=${NAMESPACE}

echo "Create TLS Cert/Key pairs for Quay Deployment..." >&2
ocp_base_domain_name=$(oc get dns/cluster -o jsonpath="{.spec.baseDomain}")
printf "\nocp_base_domain_name\n"

#In Prow, base domain is longer, like: ci-op-w3ki37mj-cc978.qe.devcluster.openshift.com
#it's easy to meet below maxsize error if len(quay_cn_name)>64
#encoding routines:ASN1_mbstring_ncopy:string too long:crypto/asn1/a_mbstr.c:107:maxsize=64
quay_cn_wildcard_name="apps."$ocp_base_domain_name
quay_cn_name="quay.${quay_cn_wildcard_name}"
quay_name="${QUAYREGISTRY}-quay-${NAMESPACE}.${quay_cn_wildcard_name}"
quay_builder_route="${QUAYREGISTRY}-quay-builder-${NAMESPACE}.${quay_cn_wildcard_name}"

echo ${quay_builder_route}
echo $quay_cn_wildcard_name
echo $quay_cn_name

cat >>openssl.cnf <<EOF
[req]
req_extensions = v3_req
distinguished_name = req_distinguished_name
[req_distinguished_name]
[ v3_req ]
basicConstraints = CA:FALSE
keyUsage = nonRepudiation, digitalSignature, keyEncipherment
subjectAltName = @alt_names
[alt_names]
DNS.1 = ${quay_name}
DNS.2 = ${quay_builder_route}
DNS.3 = ${quay_cn_name}
EOF

echo "${quay_builder_route}"

openssl genrsa -out rootCA.key 2048
openssl req -x509 -new -nodes -key rootCA.key -sha256 -days 1024 -out rootCA.pem -subj "/C=CN/ST=Beijing/L=BJ/O=Quay team/OU=Quay QE Team/CN=${quay_cn_wildcard_name}"
openssl genrsa -out ssl.key 2048
openssl req -new -key ssl.key -out ssl.csr -subj "/C=CN/ST=Beijing/L=BJ/O=Quay team/OU=Quay QE Team/CN=${quay_cn_name}"
openssl x509 -req -in ssl.csr -CA rootCA.pem -CAkey rootCA.key -CAcreateserial -out ssl.cert -days 356 -extensions v3_req -extfile openssl.cnf
cat rootCA.pem >>ssl.cert

#Get openshift CA Cert, include into secret bundle
oc extract cm/kube-root-ca.crt -n openshift-apiserver
mv ca.crt build_cluster.crt
ls -l
