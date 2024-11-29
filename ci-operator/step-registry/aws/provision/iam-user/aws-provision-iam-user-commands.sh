#!/bin/bash

set -o nounset
set -o errexit
set -o pipefail

trap 'CHILDREN=$(jobs -p); if test -n "${CHILDREN}"; then kill ${CHILDREN} && wait; fi' TERM
trap 'rm -f /tmp/aws_cred_output' EXIT TERM INT

export AWS_SHARED_CREDENTIALS_FILE="${CLUSTER_PROFILE_DIR}/.awscred"
REGION="${LEASED_RESOURCE}"
CLUSTER_NAME="${NAMESPACE}-${UNIQUE_HASH}"

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

function create_cred_file()
{
	local policy_file=$1
	local postfix=$2
	local cred_file=$3
	local policy_name policy_doc policy_outout
	local user_name policy_arn user_outout cred_outout
	local key_id key_sec

	

	echo "Policy file:"
	jq . $policy_file

	policy_name="${CLUSTER_NAME}-required-policy-${postfix}"
	policy_doc=$(cat "${policy_file}" | jq -c .)
	policy_outout=/tmp/aws_policy_output

	echo "Creating policy ${policy_name}"
	aws_create_policy $REGION "${policy_name}" "${policy_doc}" "${policy_outout}"

	user_name="${CLUSTER_NAME}-minimal-perm-${postfix}"
	policy_arn=$(jq -r '.Policy.Arn' ${policy_outout})
	user_outout=/tmp/aws_user_output
	cred_outout=/tmp/aws_cred_output

	echo "Creating user ${user_name}"
	aws_create_user $REGION "${user_name}" "${policy_arn}" "${user_outout}" "${cred_outout}"

	key_id=$(jq -r '.AccessKey.AccessKeyId' ${cred_outout})
	key_sec=$(jq -r '.AccessKey.SecretAccessKey' ${cred_outout})

	if [[ "${key_id}" == "" ]] || [[ "${key_sec}" == "" ]]; then
		echo "No AccessKeyId or SecretAccessKey, exit now"
		return 1
	fi


	echo "Key id: ${key_id} sec: ${key_sec:0:5}"
	cat <<EOF >"${cred_file}"
[default]
aws_access_key_id     = ${key_id}
aws_secret_access_key = ${key_sec}
EOF
	# for destroy
	echo ${policy_arn} >> "${SHARED_DIR}/aws_policy_arns"
	echo ${user_name} >> "${SHARED_DIR}/aws_user_names"
}

POLICY_FILE_INSTALLER="${SHARED_DIR}/aws-permissions-policy-creds.json"
POLICY_FILE_CCOCTL="${SHARED_DIR}/aws-permissions-policy-creds-ccoctl.json"

if [ -f "${POLICY_FILE_INSTALLER}" ]; then
	create_cred_file "${POLICY_FILE_INSTALLER}" "installer" "${SHARED_DIR}/aws_minimal_permission"
else
	echo "User permission policy file for installer not found. Skipping user creation"
fi

if [ -f "${POLICY_FILE_CCOCTL}" ]; then
	create_cred_file "${POLICY_FILE_CCOCTL}" "ccoctl" "${SHARED_DIR}/aws_minimal_permission_ccoctl"
else
	echo "User permission policy file for ccoctl not found. Skipping user creation"
fi
