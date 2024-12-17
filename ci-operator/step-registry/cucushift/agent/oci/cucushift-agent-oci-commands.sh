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
/tmp/install.sh --accept-all-defaults --exec-dir /tmp

CONFIG_DIR="/var/run/vault/secrets"
REGION=$(<"${CONFIG_DIR}"/region)
export OCI_CLI_KEY_FILE=${CONFIG_DIR}/oci-privatekey
export OCI_CLI_CONFIG_FILE=${CONFIG_DIR}/config
export OCI_CLI_SUPPRESS_FILE_PERMISSIONS_WARNING=True

COMPARTMENT_ID=$(<"${CONFIG_DIR}"/compartment-id)
TEMPLATE_ID=$(<"${CONFIG_DIR}"/template-id)
TENANCY_ID=$(<"${CONFIG_DIR}"/tenancy-id)
DNS_ZONE="abi-ci-${UNIQUE_HASH}-$(<${CONFIG_DIR}/dns-zone)"

echo "${NAMESPACE}-${UNIQUE_HASH}" >"${SHARED_DIR}"/cluster-name.txt
CLUSTER_NAME=$(<"${SHARED_DIR}"/cluster-name.txt)

CREATED_STACK_ID=$(/tmp/oci resource-manager stack create-from-template \
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

echo "${CREATED_STACK_ID}" >"${SHARED_DIR}"/stack-id.txt

echo "Creating Apply Job"
/tmp/oci resource-manager job create-apply-job \
--stack-id "${CREATED_STACK_ID}" \
--execution-plan-strategy AUTO_APPROVED \
--max-wait-seconds 2400 \
--wait-for-state SUCCEEDED

echo "Creating Destroy Job"
/tmp/oci resource-manager job create-destroy-job \
--stack-id "${CREATED_STACK_ID}" \
--execution-plan-strategy=AUTO_APPROVED \
--max-wait-seconds 2400 \
--wait-for-state SUCCEEDED

#echo "Deleting Stack"
#/tmp/oci resource-manager stack delete --stack-id "${CREATED_STACK_ID}" --force

