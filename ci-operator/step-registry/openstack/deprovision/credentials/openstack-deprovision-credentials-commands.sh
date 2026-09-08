#!/bin/bash

set -o nounset
set -o errexit
set -o pipefail

info() {
	>&2 printf '%s: %s\n' "$(date --utc +%Y-%m-%dT%H:%M:%SZ)" "$*"
}

CLOUDS_YAML="${SHARED_DIR}/clouds.yaml"
CLOUDS_YAML_UNRESTRICTED="${SHARED_DIR}/clouds-unrestricted.yaml"

if ! [[ -f "$CLOUDS_YAML_UNRESTRICTED" ]]; then
	info 'Unrestricted credentials not found. Exiting.'
	exit 0
fi

delete_application_credential() {
	declare OS_CLIENT_CONFIG_FILE clouds_yaml auth_type application_credential_id

	clouds_yaml="$1"
	auth_type="$(yq -r ".clouds.\"${OS_CLOUD}\".auth_type" "$clouds_yaml")"
	case "$auth_type" in
		v3applicationcredential)
			application_credential_id="$(yq -r ".clouds.\"${OS_CLOUD}\".auth.application_credential_id" "$clouds_yaml")"
			info "Deleting application credentials with ID ${application_credential_id}"
			export OS_CLIENT_CONFIG_FILE="$CLOUDS_YAML_UNRESTRICTED"
			openstack application credential delete "$application_credential_id"
			;;
		*)
			info "Detected auth_type '${auth_type}'. Doing nothing."
			;;
	esac
}


if [[ -f "$CLOUDS_YAML" ]]; then
	info 'Deleting the credentials that were used so far...'
	delete_application_credential "$CLOUDS_YAML"
fi

info 'Deleting the unrestricted credentials...'
delete_application_credential "$CLOUDS_YAML_UNRESTRICTED"
