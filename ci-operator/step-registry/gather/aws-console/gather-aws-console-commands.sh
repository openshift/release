#!/bin/bash

set -o nounset
set -o errexit
set -o pipefail

trap 'CHILDREN=$(jobs -p); if test -n "${CHILDREN}"; then kill ${CHILDREN} && wait; fi' TERM

export AWS_SHARED_CREDENTIALS_FILE="${CLUSTER_PROFILE_DIR}/.awscred"

if test ! -f "${SHARED_DIR}/metadata.json"
then
	echo "No metadata.json, so unknown AWS region, so unable to gathering console logs."
	exit 0
fi

if test -f "${KUBECONFIG}"
then
	oc --request-timeout=5s get nodes -o jsonpath --template '{range .items[*]}{.spec.providerID}{"\n"}{end}' | sed 's|.*/||' > "${TMPDIR}/node-provider-IDs.txt" &
	wait "$!"

	oc --request-timeout=5s -n openshift-machine-api get machines -o jsonpath --template '{range .items[*]}{.spec.providerID}{"\n"}{end}' | sed 's|.*/||' >> "${TMPDIR}/node-provider-IDs.txt" &
	wait "$!"
else
	echo "No kubeconfig; skipping providerID extraction."
fi

if test -f "${SHARED_DIR}/aws-instance-ids.txt"
then
	cat "${SHARED_DIR}/aws-instance-ids.txt" >> "${TMPDIR}/node-provider-IDs.txt"
fi

REGION="$(jq -r .aws.region "${SHARED_DIR}/metadata.json")"
cat "${TMPDIR}/node-provider-IDs.txt" | sort | uniq | while read -r INSTANCE_ID
do
	echo "Gathering console logs for ${INSTANCE_ID}"
	aws --region "${REGION}" ec2 get-console-output --instance-id "${INSTANCE_ID}" --output text > "${ARTIFACT_DIR}/${INSTANCE_ID}" &
	wait "$!"
done
