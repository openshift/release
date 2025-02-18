#!/bin/bash

set -o nounset
set -o errexit
set -o pipefail


GCP_AUTH_JSON=$(cat /var/run/quay-qe-gcp-secret/auth.json)

#Copy GCP auth.json from mounted secret to current directory
mkdir -p QUAY_GCP && cd QUAY_GCP
cp /var/run/quay-qe-gcp-secret/auth.json . 
echo $GCP_AUTH_JSON > auth1.json

diff auth.json auth1.json

echo "Fetch auth.json for Google Cloud SQL provision..." 
echo "Database version is $DB_VERSION"
sleep 10m
# temp_dir=$(mktemp -d)


#Get openshift CA Cert, include into secret bundle
# oc extract cm/kube-root-ca.crt -n openshift-apiserver --confirm
# create_cert || true
# echo "gcp-sql cert successfully created"

#Finally Copy certs to SHARED_DIR and archive them
# trap copyCerts EXIT
