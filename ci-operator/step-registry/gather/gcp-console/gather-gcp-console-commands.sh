#!/bin/bash

set -o nounset
set -o errexit
set -o pipefail

trap 'CHILDREN=$(jobs -p); if test -n "${CHILDREN}"; then kill ${CHILDREN} && wait; fi' TERM

export GOOGLE_CLOUD_KEYFILE_JSON="${CLUSTER_PROFILE_DIR}/gce.json"
gcloud auth activate-service-account --key-file="${GOOGLE_CLOUD_KEYFILE_JSON}"

if test ! -f "${SHARED_DIR}/metadata.json"
then
	echo "No metadata.json, so unknown GCP project, so unable to gathering console logs."
	exit 0
fi

gcloud config set project "$(jq -r .gcp.projectID "${SHARED_DIR}/metadata.json")"

if test -f "${KUBECONFIG}"
then
	oc --request-timeout=5s get nodes -o jsonpath --template '{range .items[*]}{.spec.providerID}{"\n"}{end}' | sed 's|.*/||' > "${TMPDIR}/node-provider-IDs.txt" &
	wait "$!"

	oc --request-timeout=5s -n openshift-machine-api get machines -o jsonpath --template '{range .items[*]}{.spec.providerID}{"\n"}{end}' | sed 's|.*/||' >> "${TMPDIR}/node-provider-IDs.txt" &
	wait "$!"
else
	echo "No kubeconfig; skipping providerID extraction."
fi

if test -f "${SHARED_DIR}/gcp-instance-ids.txt"
then
	cat "${SHARED_DIR}/gcp-instance-ids.txt" >> "${TMPDIR}/node-provider-IDs.txt"
fi

cat "${TMPDIR}/node-provider-IDs.txt" | sort | grep . | uniq | while read -r INSTANCE_ID
do
	echo "Finding the zone for ${INSTANCE_ID}"
	ZONE="$(
		gcloud --format json compute instances list "--filter=name=(${INSTANCE_ID})" | jq -r '.[].zone' &
		wait "$!"
	)"
	if test -z "${ZONE}"
	then
		echo "No zone found for ${INSTANCE_ID}, so not attempting to gather console logs"
		continue
	fi
	echo "Gathering console logs for ${INSTANCE_ID} from ${ZONE}"
	gcloud --format json compute instances get-serial-port-output --zone "${ZONE}" "${INSTANCE_ID}" > "${ARTIFACT_DIR}/${INSTANCE_ID}.json" &
	wait "$!"
done
