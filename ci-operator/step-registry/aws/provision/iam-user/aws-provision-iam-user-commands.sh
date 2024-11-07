#!/bin/bash

set -o nounset
set -o errexit
set -o pipefail

trap 'CHILDREN=$(jobs -p); if test -n "${CHILDREN}"; then kill ${CHILDREN} && wait; fi' TERM
trap 'rm -f /tmp/aws_cred_output' EXIT TERM INT

export AWS_SHARED_CREDENTIALS_FILE="${CLUSTER_PROFILE_DIR}/.awscred"

function run_command() {
	local cmd="$1"
	echo "Running Command: ${cmd}"
	eval "${cmd}"
}

function aws_create_policy() {
	local aws_region=$1
	local policy_name=$2
	local policy_doc=$3
	local output_json="$4"

	cmd="aws --region $aws_region iam create-policy --policy-name ${policy_name} --policy-document '${policy_doc}' > '${output_json}'"
	run_command "${cmd}" || return 1
	return 0
}

function aws_create_user() {
	local aws_region=$1
	local user_name=$2
	local policy_arn=$3
	local user_output=$4
	local access_key_output=$5

	# create user
	cmd="aws --region ${aws_region} iam create-user --user-name ${user_name} > '${user_output}'"
	run_command "${cmd}" || return 1

	# attach policy
	cmd="aws --region ${aws_region} iam attach-user-policy --user-name ${user_name} --policy-arn '${policy_arn}'"
	run_command "${cmd}" || return 1

	# create access key
	cmd="aws --region ${aws_region} iam create-access-key --user-name ${user_name} > '${access_key_output}'"
	run_command "${cmd}" || return 1

	return 0
}

REGION="${LEASED_RESOURCE}"
CLUSTER_NAME="${NAMESPACE}-${UNIQUE_HASH}"
PERMISSIONS_POLICY_FILENAME="aws-permissions-policy-creds.json"
USER_POLICY_FILE="${SHARED_DIR}/${PERMISSIONS_POLICY_FILENAME}"
USER_CREDENTIALS_OUTPUT_FILENAME="aws_minimal_permission"

if [ ! -f ${USER_POLICY_FILE} ]; then
	echo "User permission policy file not found. Skipping user creation"
	exit 0
fi

echo "Policy file:"
jq . $USER_POLICY_FILE

POLICY_NAME="${CLUSTER_NAME}-required-policy"
POLICY_DOC=$(cat "${USER_POLICY_FILE}" | jq -c .)
POLICY_OUTOUT=/tmp/aws_policy_output

echo "Creating policy ${POLICY_NAME}"
aws_create_policy $REGION "${POLICY_NAME}" "${POLICY_DOC}" "${POLICY_OUTOUT}"

USER_NAME="${CLUSTER_NAME}-minimal-perm"
POLICY_ARN=$(jq -r '.Policy.Arn' ${POLICY_OUTOUT})
USER_OUTOUT=/tmp/aws_user_output
CRED_OUTOUT=/tmp/aws_cred_output

echo "Creating user ${USER_NAME}"
aws_create_user $REGION "${USER_NAME}" "${POLICY_ARN}" "${USER_OUTOUT}" "${CRED_OUTOUT}"

key_id=$(jq -r '.AccessKey.AccessKeyId' ${CRED_OUTOUT})
key_sec=$(jq -r '.AccessKey.SecretAccessKey' ${CRED_OUTOUT})

if [[ "${key_id}" == "" ]] || [[ "${key_sec}" == "" ]]; then
	echo "No AccessKeyId or SecretAccessKey, exit now"
	exit 1
fi

echo "Key id: ${key_id} sec: ${key_sec:0:5}"
cat <<EOF >"${SHARED_DIR}/${USER_CREDENTIALS_OUTPUT_FILENAME}"
[default]
aws_access_key_id     = ${key_id}
aws_secret_access_key = ${key_sec}
EOF

# for destroy
echo ${POLICY_ARN} >"${SHARED_DIR}/aws_policy_arns"
echo ${USER_NAME} >"${SHARED_DIR}/aws_user_names"
