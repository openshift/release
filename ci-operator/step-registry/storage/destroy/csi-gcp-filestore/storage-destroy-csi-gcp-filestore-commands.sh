#!/bin/bash
set -o errexit
set -o nounset
set -o pipefail

python3 --version 
export CLOUDSDK_PYTHON=python3

# Retry transient gcloud failures (DNS blips, 429s) with exponential backoff.
# Same helper used by other GCP deprovision steps. Logs go to stderr so callers
# can capture command stdout (e.g. instance list).
function backoff() {
	local attempt=0
	local failed=0
	echo "INFO: Running Command '$*'" >&2
	while true; do
		"$@" && failed=0 || failed=1
		if [[ $failed -eq 0 ]]; then
			break
		fi
		attempt=$(( attempt + 1 ))
		if [[ $attempt -gt 5 ]]; then
			break
		fi
		echo "command failed, retrying in $(( 2 ** attempt )) seconds" >&2
		sleep $(( 2 ** attempt ))
	done
	return $failed
}

if test -f "${SHARED_DIR}/proxy-conf.sh"
then
        # shellcheck disable=SC1090
        source "${SHARED_DIR}/proxy-conf.sh"
fi

CLUSTER_ID="$(oc get -o jsonpath='{.status.infrastructureName}{"\n"}' infrastructure cluster)"
export CLUSTER_ID

export GOOGLE_CLOUD_KEYFILE_JSON="${CLUSTER_PROFILE_DIR}/gce.json"
backoff gcloud auth activate-service-account --key-file="${GOOGLE_CLOUD_KEYFILE_JSON}"

if test ! -f "${SHARED_DIR}/metadata.json"
then
	echo "No metadata.json, so unknown GCP project."
	exit 0
fi

backoff gcloud config set project "$(jq -r .gcp.projectID "${SHARED_DIR}/metadata.json")"

INSTANCES=$(backoff gcloud filestore instances list --filter "labels.kubernetes-io-cluster-$CLUSTER_ID=owned" --uri)
for i in $INSTANCES; do
    echo "Deleting Filestore instance $i"
    backoff gcloud filestore instances delete "$i" --async --force --quiet
done
