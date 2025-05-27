#!/bin/bash

set -o nounset
set -o errexit
set -o pipefail

trap 'CHILDREN=$(jobs -p); if test -n "${CHILDREN}"; then kill ${CHILDREN} && wait; fi' TERM

REGION=$(<"${CLUSTER_PROFILE_DIR}"/region)
USER=$(<"${CLUSTER_PROFILE_DIR}"/user)
FINGERPRINT=$(<"${CLUSTER_PROFILE_DIR}"/fingerprint)
COMPARTMENT_ID=$(<"${CLUSTER_PROFILE_DIR}"/compartment-id)
TEMPLATE_ID=$(<"${CLUSTER_PROFILE_DIR}"/template-id)
TENANCY_ID=$(<"${CLUSTER_PROFILE_DIR}"/tenancy-id)
CONTENT=$(<"${CLUSTER_PROFILE_DIR}"/oci-privatekey)

export OCI_CLI_USER=${USER}
export OCI_CLI_TENANCY=${TENANCY_ID}
export OCI_CLI_FINGERPRINT=${FINGERPRINT}
export OCI_CLI_KEY_CONTENT=${CONTENT}
export OCI_CLI_REGION=${REGION}

echo "${NAMESPACE}-${UNIQUE_HASH}" >"${SHARED_DIR}"/cluster-name.txt
CLUSTER_NAME=$(<"${SHARED_DIR}"/cluster-name.txt)
DNS_ZONE="abi-ci-${UNIQUE_HASH}.$(<"${CLUSTER_PROFILE_DIR}"/dns-zone)"
echo "${DNS_ZONE}" >"${SHARED_DIR}"/base-domain.txt

echo "Creating Stack"
STACK_ID=$(oci resource-manager stack create-from-template \
--compartment-id "${COMPARTMENT_ID}" \
--template-id "${TEMPLATE_ID}" \
--terraform-version 1.2.x \
--variables '{"openshift_image_source_uri":"",
"zone_dns":"'"${DNS_ZONE}"'",
"installation_method":"Agent-based",
"cluster_name":"'"${CLUSTER_NAME}"'",
"tenancy_ocid":"'"${TENANCY_ID}"'",
"create_openshift_instances":false,
"compartment_ocid":"'"${COMPARTMENT_ID}"'",
"region":"'"${REGION}"'"}' \
--query 'data.id' --raw-output)

echo "${STACK_ID}" >"${SHARED_DIR}"/stack-id.txt

echo "Creating Apply Job"
JOB_ID=$(oci resource-manager job create-apply-job \
--stack-id "${STACK_ID}" \
--execution-plan-strategy AUTO_APPROVED \
--max-wait-seconds 2400 \
--wait-for-state SUCCEEDED \
--query 'data.id' --raw-output)

echo "${JOB_ID}" >"${SHARED_DIR}"/job-id.txt

echo "$(date -u --rfc-3339=seconds) - Creating platform-conf.sh file for further installation steps..."
cat >>"${SHARED_DIR}/platform-conf.sh" <<EOF
export OCI_CLI_USER=${OCI_CLI_USER}
export OCI_CLI_TENANCY=${OCI_CLI_TENANCY}
export OCI_CLI_FINGERPRINT=${OCI_CLI_FINGERPRINT}
export OCI_CLI_REGION=${OCI_CLI_REGION}
export COMPARTMENT_ID=${COMPARTMENT_ID}
export TEMPLATE_ID=${TEMPLATE_ID}
export STACK_ID=${STACK_ID}
export JOB_ID=${JOB_ID}
EOF
