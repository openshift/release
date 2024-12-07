#!/usr/bin/env bash

set -o nounset
set -o errexit
set -o pipefail

if [[ "${CONFIG_TYPE}" == *"proxy"* || "$CONFIG_TYPE" == *"dualstack"* || "$CONFIG_TYPE" == *"singlestackv6"* ]]; then
    echo "Skipping step due to CONFIG_TYPE being '${CONFIG_TYPE}'."
    exit 0
fi

export OS_CLIENT_CONFIG_FILE="${SHARED_DIR}/clouds.yaml"
CLUSTER_NAME="$(<"${SHARED_DIR}/CLUSTER_NAME")"
OPENSTACK_EXTERNAL_NETWORK="${OPENSTACK_EXTERNAL_NETWORK:-$(<"${SHARED_DIR}/OPENSTACK_EXTERNAL_NETWORK")}"

if [[ "${ENABLE_HIVE_FIP}" == "true" ]]; then 
  HIVE_CLUSTER_NAME="${CLUSTER_NAME}-hive"
  echo "${HIVE_CLUSTER_NAME}" > "${SHARED_DIR}/HIVE_CLUSTER_NAME" || { echo "Failed to write HIVE_CLUSTER_NAME"; exit 1; }
fi

collect_artifacts() {
	for f in API_IP INGRESS_IP DELETE_FIPS; do
		if [[ -f "${SHARED_DIR}/${f}" ]]; then
			cp "${SHARED_DIR}/${f}" "${ARTIFACT_DIR}/"
		fi
	done

	 if [[ "${ENABLE_HIVE_FIP}" == "true" ]]; then
        for m in HIVE_FIP_API HIVE_FIP_INGRESS HIVE_DELETE_FIPS; do
			if [[ -f "${SHARED_DIR}/${m}" ]]; then
				cp "${SHARED_DIR}/${m}" "${ARTIFACT_DIR}/"
			fi
		done
    fi
}
trap collect_artifacts EXIT TERM

if [[ "${API_FIP_ENABLED}" == "true" ]]; then
	echo "Creating floating IP for API"
	API_FIP=$(openstack floating ip create \
		--description "${CLUSTER_NAME}.api-fip" \
		--tag "PROW_CLUSTER_NAME=${CLUSTER_NAME}" \
		--tag "PROW_JOB_ID=${PROW_JOB_ID}" \
		"$OPENSTACK_EXTERNAL_NETWORK" \
		--format json -c floating_ip_address -c id)
	jq -r '.floating_ip_address' <<<"$API_FIP" >  "${SHARED_DIR}/API_IP"
	jq -r '.id'                  <<<"$API_FIP" >> "${SHARED_DIR}/DELETE_FIPS"
fi

if [[ "${INGRESS_FIP_ENABLED}" == "true" ]]; then
	echo "Creating floating IP for Ingress"
	INGRESS_FIP="$(openstack floating ip create \
			--description "${CLUSTER_NAME}.ingress-fip" \
			--tag "PROW_CLUSTER_NAME=${CLUSTER_NAME}" \
			--tag "PROW_JOB_ID=${PROW_JOB_ID}" \
			"$OPENSTACK_EXTERNAL_NETWORK" \
			--format json -c floating_ip_address -c id)"
	jq -r '.floating_ip_address' <<<"$INGRESS_FIP" >  "${SHARED_DIR}/INGRESS_IP"
	jq -r '.id'                  <<<"$INGRESS_FIP" >> "${SHARED_DIR}/DELETE_FIPS"
fi

if [[ "${ENABLE_HIVE_FIP}" == "true" ]]; then
	echo "Creating floating IP for Hive"
	HIVE_API_FIP=$(openstack floating ip create \
		--description "${HIVE_CLUSTER_NAME}.api-fip" \
		--tag "PROW_CLUSTER_NAME=${CLUSTER_NAME}" \
		--tag "PROW_JOB_ID=${PROW_JOB_ID}" \
		"$OPENSTACK_EXTERNAL_NETWORK" \
		--format json -c floating_ip_address -c id)
	jq -r '.floating_ip_address' <<<"$HIVE_API_FIP" >  "${SHARED_DIR}/HIVE_FIP_API"
	jq -r '.id'                  <<<"$HIVE_API_FIP" >> "${SHARED_DIR}/HIVE_DELETE_FIPS"
	echo "Hive API floating IP: $(<"${SHARED_DIR}/HIVE_FIP_API")"
	echo "Hive API floating IP ID: $(<"${SHARED_DIR}/HIVE_DELETE_FIPS")"

	echo "Creating Ingress flosting IP for Hive"
	HIVE_INGRESS_FIP=$(openstack floating ip create \
		--description "${HIVE_CLUSTER_NAME}.ingress-fip" \
		--tag "PROW_CLUSTER_NAME=${CLUSTER_NAME}" \
		--tag "PROW_JOB_ID=${PROW_JOB_ID}" \
		"$OPENSTACK_EXTERNAL_NETWORK" \
		--format json -c floating_ip_address -c id)
	jq -r '.floating_ip_address' <<<"$HIVE_INGRESS_FIP" >  "${SHARED_DIR}/HIVE_FIP_INGRESS"
	jq -r '.id'                  <<<"$HIVE_INGRESS_FIP" >> "${SHARED_DIR}/HIVE_DELETE_FIPS"
	echo "Hive Ingress floating IP: $(<"${SHARED_DIR}/HIVE_FIP_INGRESS")"
	echo "Hive Ingress floating IP ID: $(<"${SHARED_DIR}/HIVE_DELETE_FIPS")"
fi