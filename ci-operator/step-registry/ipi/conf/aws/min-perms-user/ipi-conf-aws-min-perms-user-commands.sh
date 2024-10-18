#!/bin/bash

set -o nounset
set -o errexit
set -o pipefail

trap 'CHILDREN=$(jobs -p); if test -n "${CHILDREN}"; then kill ${CHILDREN} && wait; fi' TERM
trap 'rm -rf /tmp/aws_cred_output /tmp/pull-secret /tmp/min_perms/' EXIT TERM INT

function run_command() {
	local cmd="$1"
	echo "Running Command: ${cmd}"
	eval "${cmd}"
}

function installer_generate_policies() {
	local dir=/tmp/min_perms/

	mkdir -p ${dir}

	# Make a copy of the install-config.yaml since the installer will consume it.
	cp "${SHARED_DIR}/install-config.yaml" ${dir}/

	cmd="openshift-install create permissions-policy --dir ${dir}"
	run_command "${cmd}" || return 1

	# Save policies to shared dir so later steps have access to it.
	mv ${dir}/*-creds.json ${SHARED_DIR}/

	return 0
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

if [[ "${AWS_INSTALL_USE_MINIMAL_PERMISSIONS}" != "yes" ]]; then
	echo "Custom AWS user with minimal permissions is disabled. Using AWS user from cluster profile."
	exit 0
fi

RELEASE_IMAGE_INSTALL="${RELEASE_IMAGE_INITIAL:-}"
if [[ -z "${RELEASE_IMAGE_INSTALL}" ]]; then
	# If there is no initial release, we will be installing latest.
	RELEASE_IMAGE_INSTALL="${RELEASE_IMAGE_LATEST:-}"
fi
cp ${CLUSTER_PROFILE_DIR}/pull-secret /tmp/pull-secret
oc registry login --to /tmp/pull-secret
ocp_version=$(oc adm release info --registry-config /tmp/pull-secret ${RELEASE_IMAGE_INSTALL} --output=json | jq -r '.metadata.version' | cut -d. -f 1,2)
ocp_major_version=$(echo "${ocp_version}" | awk --field-separator=. '{print $1}')
ocp_minor_version=$(echo "${ocp_version}" | awk --field-separator=. '{print $2}')
rm /tmp/pull-secret

export AWS_SHARED_CREDENTIALS_FILE="${CLUSTER_PROFILE_DIR}/.awscred"

REGION="${LEASED_RESOURCE}"
CLUSTER_NAME="${NAMESPACE}-${UNIQUE_HASH}"

if ((ocp_major_version < 4 || (ocp_major_version == 4 && ocp_minor_version < 18))); then
	# FIXME: generate an ad-hoc policy here
	echo "Openshift installer cannot generate permissions policy prior to release 4.18"
	exit 1
else
	installer_generate_policies
fi

USER_POLICY_FILE="${SHARED_DIR}/aws-permissions-policy-creds.json"
POLICY_NAME="${CLUSTER_NAME}-required-policy"
POLICY_DOC=$(jq -c <${USER_POLICY_FILE})
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
cat <<EOF >"${SHARED_DIR}/aws_minimal_permission"
[default]
aws_access_key_id     = ${key_id}
aws_secret_access_key = ${key_sec}
EOF

# for destroy
echo ${POLICY_ARN} >"${SHARED_DIR}/aws_policy_arns"
echo ${USER_NAME} >"${SHARED_DIR}/aws_user_names"
