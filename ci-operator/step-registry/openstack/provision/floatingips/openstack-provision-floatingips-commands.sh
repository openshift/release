#!/usr/bin/env bash

set -o nounset
set -o errexit
set -o pipefail

if [[ "${CONFIG_TYPE}" == "proxy" ]]; then
    echo "Skipping step due to CONFIG_TYPE being '${CONFIG_TYPE}'."
    exit 0
fi

export OS_CLIENT_CONFIG_FILE="${SHARED_DIR}/clouds.yaml"
CLUSTER_NAME="$(<"${SHARED_DIR}/CLUSTER_NAME")"
OPENSTACK_EXTERNAL_NETWORK="${OPENSTACK_EXTERNAL_NETWORK:-$(<"${SHARED_DIR}/OPENSTACK_EXTERNAL_NETWORK")}"

collect_artifacts() {
	for f in API_IP INGRESS_IP DELETE_FIPS; do
		if [[ -f "${SHARED_DIR}/${f}" ]]; then
			cp "${SHARED_DIR}/${f}" "${ARTIFACT_DIR}/"
		fi
	done
}
trap collect_artifacts EXIT TERM

API_FIP=$(openstack floating ip create \
		--description "$CLUSTER_NAME.api-fip" \
		"$OPENSTACK_EXTERNAL_NETWORK" \
		--format json -c floating_ip_address -c id)
jq -r '.floating_ip_address' <<<"$API_FIP" >  "${SHARED_DIR}/API_IP"
jq -r '.id'                  <<<"$API_FIP" >> "${SHARED_DIR}/DELETE_FIPS"

INGRESS_FIP="$(openstack floating ip create \
		--description "${CLUSTER_NAME}.ingress-fip" \
		"$OPENSTACK_EXTERNAL_NETWORK" \
		--format json -c floating_ip_address -c id)"
jq -r '.floating_ip_address' <<<"$INGRESS_FIP" >  "${SHARED_DIR}/INGRESS_IP"
jq -r '.id'                  <<<"$INGRESS_FIP" >> "${SHARED_DIR}/DELETE_FIPS"
