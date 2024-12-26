#!/bin/bash

set -o nounset
set -o errexit
set -o pipefail

trap 'CHILDREN=$(jobs -p); if test -n "${CHILDREN}"; then kill ${CHILDREN} && wait; fi' TERM
# Ensure our UID, which is randomly generated, is in /etc/passwd. This is required to be able to SSH.
if ! whoami &>/dev/null; then
  if [[ -w /etc/passwd ]]; then
    echo "${USER_NAME:-default}:x:$(id -u):0:${USER_NAME:-default} user:${HOME}:/sbin/nologin" >>/etc/passwd
  else
    echo "/etc/passwd is not writeable, and user matching this uid is not found."
    exit 1
  fi
fi
curl -L https://raw.githubusercontent.com/oracle/oci-cli/master/scripts/install/install.sh -o /tmp/install.sh
chmod +x /tmp/install.sh
/tmp/install.sh --accept-all-defaults --exec-dir /tmp 2>/dev/null

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
DNS_ZONE="abi-ci-${UNIQUE_HASH}-$(<${CLUSTER_PROFILE_DIR}/dns-zone)"
echo "${DNS_ZONE}" >"${SHARED_DIR}"/base-domain.txt

STACK_ID=$(/tmp/oci resource-manager stack create-from-template \
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
JOB_ID=$(/tmp/oci resource-manager job create-apply-job \
--stack-id "${STACK_ID}" \
--execution-plan-strategy AUTO_APPROVED \
--max-wait-seconds 2400 \
--wait-for-state SUCCEEDED \
--query 'data.id' --raw-output)

echo "${JOB_ID}" >"${SHARED_DIR}"/job-id.txt
#echo "Creating Destroy Job"
#/tmp/oci resource-manager job create-destroy-job \
#--stack-id "${CREATED_STACK_ID}" \
#--execution-plan-strategy=AUTO_APPROVED \
#--max-wait-seconds 2400 \
#--wait-for-state SUCCEEDED

#echo "Deleting Stack"
#/tmp/oci resource-manager stack delete --stack-id "${CREATED_STACK_ID}" --force

