#!/bin/bash

set -o nounset
set -o errexit
set -o pipefail

REGION="${LEASED_RESOURCE}"
CLUSTER_NAME="${NAMESPACE}-${UNIQUE_HASH}"
export AWS_SHARED_CREDENTIALS_FILE="${CLUSTER_PROFILE_DIR}/.awscred"

if [[ ${ENABLE_SHARED_PHZ} != "yes" ]]; then
	echo "This step can be only used in Shared-VPC (PHZ) cluster."
	exit 1
fi



if [[ -f "${SHARED_DIR}/aws_minimal_permission" ]]; then
  CLUSTER_CREATOR_USER_ARN=$(aws iam get-user --user-name ${CLUSTER_NAME}-minimal-perm-installer | jq -r '.User.Arn')
else
  CLUSTER_CREATOR_USER_ARN=$(aws sts get-caller-identity | jq -r '.Arn')
fi

PRINCIPAL_LIST=$(mktemp)
echo ${CLUSTER_CREATOR_USER_ARN} > ${PRINCIPAL_LIST}

ASSUME_ROLE_POLICY_DOC=$(mktemp)
if [[ -e ${SHARED_DIR}/sts_ingress_role_arn ]]; then
  ingress_role=$(head -n 1 ${SHARED_DIR}/sts_ingress_role_arn)
  if [[ ${ingress_role} == "" ]]; then
    echo "Ingress role is empty, exit now"
    exit 1
  else
    echo ${ingress_role} >> ${PRINCIPAL_LIST}
  fi 
fi

cat <<EOF> $ASSUME_ROLE_POLICY_DOC
{
    "Version": "2012-10-17",
    "Statement": [
        {
            "Effect": "Allow",
            "Principal": {
                "AWS": $(cat ${PRINCIPAL_LIST} | jq -Rn '[inputs]')
            },
            "Action": "sts:AssumeRole",
            "Condition": {}
        }
    ]
}
EOF

# update ingress operator user in trust policy

if [[ ! -e "${CLUSTER_PROFILE_DIR}/.awscred_shared_account" ]]; then
  echo "Error: .awscred_shared_account not found in cluster profile, exit now"
  exit 1
fi

export AWS_SHARED_CREDENTIALS_FILE="${CLUSTER_PROFILE_DIR}/.awscred_shared_account"

role_name=$(head -n 1 ${SHARED_DIR}/shared_install_role_name)
echo "Updating trust policy for ${role_name} ..."
cat $ASSUME_ROLE_POLICY_DOC
aws --region $REGION iam update-assume-role-policy --role-name ${role_name} --policy-document file://${ASSUME_ROLE_POLICY_DOC}
