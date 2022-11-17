#!/bin/bash

set -o nounset
set -o errexit
set -o pipefail

info() {
	printf '%s: %s\n' "$(date --utc +%Y-%m-%dT%H:%M:%SZ)" "$*"
}

if ! [ -r "${SHARED_DIR}/clouds2.yaml" ]; then
	echo 'clouds.yaml with alternative credentials not found. Exiting.'
	exit 1
fi

if ! [ -r "${SHARED_DIR}/clouds-unrestricted.yaml" ]; then
	echo 'clouds.yaml with unrestricted credentials, that required to delete the credentials used to install, was not found. Exiting.'
	exit 1
fi

mv "${SHARED_DIR}"/clouds{,-original}.yaml
mv "${SHARED_DIR}"/clouds{2,}.yaml

ORIGINAL_CLOUDS_YAML="${SHARED_DIR}/clouds-original.yaml"
ALTERNATIVE_CLOUDS_YAML="${SHARED_DIR}/clouds.yaml"
UNRESTRICTED_CLOUDS_YAML="${SHARED_DIR}/clouds-unrestricted.yaml"

delete_application_credential() {
	declare OS_CLIENT_CONFIG_FILE clouds_yaml application_credential_id

	clouds_yaml="$1"
	application_credential_id="$(yq -r ".clouds.\"${OS_CLOUD}\".auth.application_credential_id" "$clouds_yaml")"

	export OS_CLIENT_CONFIG_FILE="$UNRESTRICTED_CLOUDS_YAML"
	openstack application credential delete "$application_credential_id"
}

info 'Replacing clouds.yaml in the openstack-cloud-credentials secret...'
oc set data -n kube-system secret/openstack-credentials clouds.yaml="$(<"$ALTERNATIVE_CLOUDS_YAML")"

info 'Waiting for the cluster to become ready...'
declare progressing=1
while [[ $progressing -gt 0 ]]; do
	sleep 5
	progressing="$(oc get clusteroperator -o json \
			| jq '.items[].status.conditions[] | select(.type=="Progressing") | select(.status=="True").status' \
			| wc -l)"
	info "${progressing} operators progressing."
done

info 'Revoking the credentials that were used so far...'
delete_application_credential "$ORIGINAL_CLOUDS_YAML"

info 'Revoking the unrestricted credentials...'
delete_application_credential "$UNRESTRICTED_CLOUDS_YAML"

info 'Done.'
