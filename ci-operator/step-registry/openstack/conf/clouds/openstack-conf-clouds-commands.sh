#!/bin/bash

set -o nounset
set -o errexit
set -o pipefail

info() {
	>&2 printf '%s: %s\n' "$(date --utc +%Y-%m-%dT%H:%M:%SZ)" "$*"
}

CLUSTER_TYPE="${CLUSTER_TYPE_OVERRIDE:-$CLUSTER_TYPE}"
CLUSTER_NAME=''
if [ -r "${SHARED_DIR}/CLUSTER_NAME" ]; then
	CLUSTER_NAME="$(<"${SHARED_DIR}/CLUSTER_NAME")"
fi

clouds_yaml="$(mktemp)"
cp "/var/run/cluster-secrets/${CLUSTER_TYPE}/clouds.yaml" "$clouds_yaml"
if [ -f "/var/run/cluster-secrets/${CLUSTER_TYPE}/osp-ca.crt" ]; then
	cp "/var/run/cluster-secrets/${CLUSTER_TYPE}/osp-ca.crt" "${SHARED_DIR}/osp-ca.crt"
	sed -i "s|cacert: .*|cacert: ${SHARED_DIR}/osp-ca.crt|" "$clouds_yaml"
fi

if [ -f "/var/run/cluster-secrets/${CLUSTER_TYPE}/squid-credentials.txt" ]; then
	cp "/var/run/cluster-secrets/${CLUSTER_TYPE}/squid-credentials.txt" "${SHARED_DIR}/squid-credentials.txt"
fi

declare -r \
	METHOD_APPCREDS='application-credentials' \
	METHOD_PASSWORD='password' \
	METHOD_DEFAULT='version-default'

# new_application_credentials creates a new application credential set and
# merges it to the provided clouds.yaml.
new_application_credentials() {
	declare OS_CLIENT_CONFIG_FILE appcred_json
	OS_CLIENT_CONFIG_FILE="$1"
	export OS_CLIENT_CONFIG_FILE
	shift

	appcred_json="$(
		openstack application credential create \
			"${*:---restricted}" \
			--expiration "$(date -d "$APPLICATION_CREDENTIALS_EXPIRATION" +%Y-%m-%dT%H:%M:%S)" \
			--description "PROW_CLUSTER_NAME=${CLUSTER_NAME} PROW_JOB_ID=${PROW_JOB_ID}" \
			--format json --column id --column secret \
			"prow-$(date +'%s%N')"
	)"

	yq --yml-output ".
		| del(.clouds.\"${OS_CLOUD}\".auth.username)
		| del(.clouds.\"${OS_CLOUD}\".auth.password)
		| del(.clouds.\"${OS_CLOUD}\".auth.user_domain_name)
		| del(.clouds.\"${OS_CLOUD}\".auth.project_id)
		| del(.clouds.\"${OS_CLOUD}\".auth.project_name)
		| del(.clouds.\"${OS_CLOUD}\".auth.project_domain_name)
		| .clouds.\"${OS_CLOUD}\".auth_type=\"v3applicationcredential\"
		| .clouds.\"${OS_CLOUD}\".auth.application_credential_id=\"$(jq -r '.id' <<< "$appcred_json")\"
		| .clouds.\"${OS_CLOUD}\".auth.application_credential_secret=\"$(jq -r '.secret' <<< "$appcred_json")\"
		" "$OS_CLIENT_CONFIG_FILE"
}

# If both 'oc' and 'openshift-install' exist in $PATH, then apply OCP
# authentication method selection. Otherwise, default to application
# credentials.
if command -v oc &> /dev/null && command -v openshift-install &> /dev/null; then
	is_openshift_version_gte() {
		declare release_image ocp_version
		release_image="$(openshift-install version | sed -n 's/^release image\s\+\(.*\)$/\1/p' | tr -d '\n')"
		ocp_version="$(oc adm release info "$release_image" -o json | jq -r '.metadata.version' | tr -d '\n')"
		info "Detected OCP version: ${ocp_version}"
		printf '%s\n%s' "$1" "$ocp_version" | sort -C -V
	}

	# Loudly crash if "application-credentials" was explicitly set on an incompatible OCP version
	if [[ "$OPENSTACK_AUTHENTICATION_METHOD" == "$METHOD_APPCREDS" ]] && ! is_openshift_version_gte "4.12"; then
		info 'Detected OPENSTACK_AUTHENTICATION_METHOD=application-credentials in combination with an incompatible OCP version: exiting with an error.'
		exit 1
	fi

	if [[ "$OPENSTACK_AUTHENTICATION_METHOD" == "$METHOD_DEFAULT" ]]; then
		if is_openshift_version_gte "4.13"; then
			info 'Detected version gte 4.13: setting application credentials authentication.'
			OPENSTACK_AUTHENTICATION_METHOD='application-credentials'
		else
			info 'Detected version lt 4.13: setting password authentication.'
			OPENSTACK_AUTHENTICATION_METHOD='password'
		fi
	fi

else
	if [[ "$OPENSTACK_AUTHENTICATION_METHOD" == "$METHOD_DEFAULT" ]]; then
		info 'Defaulting to application credentials for non-OCP jobs.'
		OPENSTACK_AUTHENTICATION_METHOD="$METHOD_APPCREDS"
	fi
fi


info "The environment variable OPENSTACK_AUTHENTICATION_METHOD is set to '${OPENSTACK_AUTHENTICATION_METHOD}'."
case "$OPENSTACK_AUTHENTICATION_METHOD" in
	"$METHOD_APPCREDS")
		new_application_credentials "$clouds_yaml" > "${SHARED_DIR}/clouds.yaml"
		info "Generated application credentials with ID $(yq -r ".clouds.\"${OS_CLOUD}\".auth.application_credential_id" "${SHARED_DIR}/clouds.yaml")"

		new_application_credentials "$clouds_yaml" --unrestricted > "${SHARED_DIR}/clouds-unrestricted.yaml"
		info "Generated unrestricted application credentials with ID $(yq -r ".clouds.\"${OS_CLOUD}\".auth.application_credential_id" "${SHARED_DIR}/clouds-unrestricted.yaml")"

		if [[ -n "$ROTATE_CLOUD_CREDENTIALS" ]]; then
			info 'Environment variable ROTATE_CLOUD_CREDENTIALS detected. Generating a set of application credentials for the rotation...'
			new_application_credentials "$clouds_yaml" > "${SHARED_DIR}/clouds2.yaml"
			info "Generated application credentials with ID $(yq -r ".clouds.\"${OS_CLOUD}\".auth.application_credential_id" "${SHARED_DIR}/clouds2.yaml")"
		fi

		;;
	"$METHOD_PASSWORD")
		if [[ "$(yq -r ".clouds.\"${OS_CLOUD}\".auth_type" "$clouds_yaml")" == 'v3applicationcredential' ]]; then
			info 'The original clouds.yaml does not contain a password. Exiting.'
			exit 1
		fi
		info 'Using password authentication with the original clouds.yaml'

		cp "$clouds_yaml" "${SHARED_DIR}/clouds.yaml"
		;;
	*)
		info "Unknown authentication method '${OPENSTACK_AUTHENTICATION_METHOD}'."; exit 1 ;;
esac
