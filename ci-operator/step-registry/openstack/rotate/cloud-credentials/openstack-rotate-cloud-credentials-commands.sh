#!/bin/bash

set -o nounset
set -o errexit
set -o pipefail

if [ -z "$ROTATE_CLOUD_CREDENTIALS" ]; then
	echo 'Environment variable ROTATE_CLOUD_CREDENTIALS unset or empty. Exiting.'
	exit 0
fi

info() {
	printf '%s: %s\n' "$(date --utc +%Y-%m-%dT%H:%M:%SZ)" "$*"
}

# For disconnected or otherwise unreachable environments, we want to
# have steps use an HTTP(S) proxy to reach the API server. This proxy
# configuration file should export HTTP_PROXY, HTTPS_PROXY, and NO_PROXY
# environment variables, as well as their lowercase equivalents (note
# that libcurl doesn't recognize the uppercase variables).
if test -f "${SHARED_DIR}/proxy-conf.sh"
then
	# shellcheck disable=SC1090
	source "${SHARED_DIR}/proxy-conf.sh"
fi

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

sleep 5

info 'Waiting for the operators to become ready...'
# shellcheck disable=SC2046
oc wait --timeout=5m --for=condition=Progressing=false $(oc get clusteroperator -o NAME) -o template='{{.metadata.name}} is ready
'

info 'Revoking the credentials that were used so far...'
delete_application_credential "$ORIGINAL_CLOUDS_YAML"

info 'Done.'
