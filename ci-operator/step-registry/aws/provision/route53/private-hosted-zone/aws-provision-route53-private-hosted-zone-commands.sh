#!/bin/bash

set -o nounset
set -o errexit
set -o pipefail

export AWS_SHARED_CREDENTIALS_FILE="${CLUSTER_PROFILE_DIR}/.awscred"
if [[ ${ENABLE_SHARED_PHZ} == "yes" ]]; then
  CLUSTER_CREATOR_USER_ARN=$(aws sts get-caller-identity | jq -r '.Arn')
  export AWS_SHARED_CREDENTIALS_FILE="${CLUSTER_PROFILE_DIR}/.awscred_shared_account"

  SHARED_ACCOUNT_NO=$(aws sts get-caller-identity | jq -r '.Arn' | awk -F ":" '{print $5}')
  echo "Using shared account to create PHZ. Account No: ${SHARED_ACCOUNT_NO:0:6}***"
fi

REGION="${LEASED_RESOURCE}"


if [[ -e ${SHARED_DIR}/rosa_dns_domain ]]; then
  # ROSA uses:
  #  * a seperate dnsdomain which managed by SRE
  #  * a seperate CLUSTER_NAME as it has some extra limitation, see step rosa-cluster-provision
  prefix="ci-rosa-s"
  subfix=$(openssl rand -hex 2)
  CLUSTER_NAME=${CLUSTER_NAME:-"$prefix-$subfix"}
  echo "${CLUSTER_NAME}" > "${SHARED_DIR}/cluster-name"

  rosa_dns_domain=$(head -n 1 ${SHARED_DIR}/rosa_dns_domain)
  ROUTE53_HOSTED_ZONE_NAME="${CLUSTER_NAME}.${rosa_dns_domain}"
else
  # For OCP clusters
  CLUSTER_NAME="${NAMESPACE}-${UNIQUE_HASH}"
  if [[ ${BASE_DOMAIN} == "" ]]; then
    echo "No base_domain provided, exit now."
    exit 1
  fi
  ROUTE53_HOSTED_ZONE_NAME="${CLUSTER_NAME}.${BASE_DOMAIN}"
fi

VPC_ID=$(cat "${SHARED_DIR}/vpc_id")
# Use a timestamp to ensure the caller reference is unique, as we've found
# cluster name can get reused in specific situations.
TIMESTAMP=$(date +%s)
CALLER_REFERENCE_STR="${ROUTE53_HOSTED_ZONE_NAME}-${TIMESTAMP}"

echo -e "creating route53 hosted zone: ${ROUTE53_HOSTED_ZONE_NAME}"
HOSTED_ZONE_CREATION=$(aws --region "$REGION" route53 create-hosted-zone --name "${ROUTE53_HOSTED_ZONE_NAME}" --vpc VPCRegion="${REGION}",VPCId="${VPC_ID}" --caller-reference "${CALLER_REFERENCE_STR}")

HOSTED_ZONE_ID="$(echo "${HOSTED_ZONE_CREATION}" | jq -r '.HostedZone.Id' | awk -F / '{printf $3}')"
# save hosted zone information to ${SHARED_DIR} for deprovision step
echo "${HOSTED_ZONE_ID}" > "${SHARED_DIR}/hosted_zone_id"
CHANGE_ID="$(echo "${HOSTED_ZONE_CREATION}" | jq -r '.ChangeInfo.Id' | awk -F / '{printf $3}')"

# add a sleep time to reduce Rate exceeded errors
sleep 120

aws --region "${REGION}" route53 wait resource-record-sets-changed --id "${CHANGE_ID}" &
wait "$!"
echo "Hosted zone ${HOSTED_ZONE_ID} successfully created."


if [[ ${ENABLE_SHARED_PHZ} == "yes" ]]; then

  # Create IAM policy
  POLICY_NAME="${CLUSTER_NAME}-shared-policy"
  POLICY_DOC=$(mktemp)
  POLICY_OUT=$(mktemp)

  # ec2:DeleteTags is requried, as some tags are added by aws-provision-tags-for-byo-vpc for ingress operator
  cat <<EOF> $POLICY_DOC
{
    "Version": "2012-10-17",
    "Statement": [
        {
            "Effect": "Allow",
            "Action": "ec2:DeleteTags",
            "Resource": "arn:aws:ec2:${REGION}:${SHARED_ACCOUNT_NO}:vpc/${VPC_ID}"
        },
        {
            "Effect": "Allow",
            "Action": [
                "route53:ChangeResourceRecordSets",
                "route53:ListHostedZones",
                "route53:ListHostedZonesByName",
                "route53:ListResourceRecordSets",
                "route53:ChangeTagsForResource",
                "route53:GetAccountLimit",
                "route53:GetChange",
                "route53:GetHostedZone",
                "route53:ListTagsForResource",
                "route53:UpdateHostedZoneComment",
                "tag:GetResources",
                "tag:UntagResources"
            ],
            "Resource": "*"
        }
    ]
}
EOF

  cmd="aws --region $REGION iam create-policy --policy-name ${POLICY_NAME} --policy-document '$(cat $POLICY_DOC | jq -c)' > ${POLICY_OUT}"
  eval "${cmd}"
  POLICY_ARN=$(cat ${POLICY_OUT} | jq -r '.Policy.Arn')
  echo "Created ${POLICY_ARN}"
  echo ${POLICY_ARN} > ${SHARED_DIR}/shared_install_policy_arn

  # Create IAM role
  ROLE_NAME="${CLUSTER_NAME}-shared-role"
  echo ${ROLE_NAME} > ${SHARED_DIR}/shared_install_role_name

  ASSUME_ROLE_POLICY_DOC=$(mktemp)
  ROLE_OUT=$(mktemp)

  PRINCIPAL_LIST=$(mktemp)
  echo ${CLUSTER_CREATOR_USER_ARN} > ${PRINCIPAL_LIST}
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

  aws --region $REGION iam create-role --role-name ${ROLE_NAME} --assume-role-policy-document file://${ASSUME_ROLE_POLICY_DOC} > $ROLE_OUT
  ROLE_ARN=$(jq -r '.Role.Arn' ${ROLE_OUT})
  echo ${ROLE_ARN} > "${SHARED_DIR}/hosted_zone_role_arn"
  echo "Created ${ROLE_ARN} with assume policy:"
  cat $ASSUME_ROLE_POLICY_DOC

  # Attach policy to role
  cmd="aws --region $REGION iam attach-role-policy --role-name ${ROLE_NAME} --policy-arn '${POLICY_ARN}'"
  eval "${cmd}"

fi
