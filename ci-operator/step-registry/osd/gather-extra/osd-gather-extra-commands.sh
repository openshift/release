#!/usr/bin/env bash

set -o nounset
set -o errexit
set -o pipefail

export AWS_SHARED_CREDENTIALS_FILE="${CLUSTER_PROFILE_DIR}/.awscred"
AWS_ACCOUNT_ID=$(cat /var/run/hcm-job-logs-s3-bucket-storage/account_id)
HIVE_LOGS_BUCKET=$(cat /var/run/hcm-job-logs-s3-bucket-storage/bucket)
CLUSTER_NAME=$(cat "${SHARED_DIR}/cluster-name")
CLUSTER_ID=$(cat "${SHARED_DIR}/cluster-id")
ROLE_ARN=arn:aws:iam::${AWS_ACCOUNT_ID}:role/ocp-trt-nightly-hive-logs-read-only
ROLE_SESSION_NAME=OSDGatherExtraInstallLogs

# shellcheck disable=SC2183,SC2046
export $(printf "AWS_ACCESS_KEY_ID=%s AWS_SECRET_ACCESS_KEY=%s AWS_SESSION_TOKEN=%s" \
	$(aws sts assume-role \
		--role-arn "${ROLE_ARN}" \
		--role-session-name "${ROLE_SESSION_NAME}" \
		--query "Credentials.[AccessKeyId,SecretAccessKey,SessionToken]" \
		--output text))

# copy from hive install bucket into artifacts dir
aws s3 cp --recursive \
	s3://"${HIVE_LOGS_BUCKET}"/"${CLUSTER_NAME}"-uhc-staging-"${CLUSTER_ID}" \
	"${ARTIFACT_DIR}"/

# save csv list of operator images
oc get csv -A -o json | jq -r '
	.items[] |
	select(.spec.install.spec.deployments != null) |
	"\(.metadata.name): " + (
		.spec.install.spec.deployments[] |
		.spec.template.spec.containers[] |
		.name
	)' | sort | uniq > "${ARTIFACT_DIR}"/operator-shas.txt
