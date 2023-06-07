#!/bin/bash
set -o errexit
set -o nounset
set -o pipefail

python3 --version 
export CLOUDSDK_PYTHON=python3

CLUSTER_ID="$(oc get -o jsonpath='{.status.infrastructureName}{"\n"}' infrastructure cluster)"
export CLUSTER_ID

export GOOGLE_CLOUD_KEYFILE_JSON="${CLUSTER_PROFILE_DIR}/gce.json"
gcloud auth activate-service-account --key-file="${GOOGLE_CLOUD_KEYFILE_JSON}"

if test ! -f "${SHARED_DIR}/metadata.json"
then
	echo "No metadata.json, so unknown GCP project."
	exit 0
fi

gcloud config set project "$(jq -r .gcp.projectID "${SHARED_DIR}/metadata.json")"

INSTANCES=$(gcloud filestore instances list --filter labels.kubernetes-io-cluster-$CLUSTER_ID=owned --uri)
for i in $INSTANCES; do
    echo "Deleting Filestore instance $i"
    gcloud filestore instances delete "$i" --async --force --quiet
done
