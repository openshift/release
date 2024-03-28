#!/bin/bash

set -o nounset
set -o errexit
set -o pipefail

# For case https://polarion.engineering.redhat.com/polarion/#/project/OSE/workitem?id=OCP-66515

trap 'CHILDREN=$(jobs -p); if test -n "${CHILDREN}"; then kill ${CHILDREN} && wait; fi' TERM
trap 'delete_resources' EXIT TERM INT

if [[ ! -e ${CLUSTER_PROFILE_DIR}/.awscred ]] || [[ ! -e ${CLUSTER_PROFILE_DIR}/.awscred_shared_account ]]; then
  echo "AWS credential file is missing, exit now."
  exit 1
fi

REGION=${LEASED_RESOURCE}
export AWS_DEFAULT_REGION=${REGION}

account_roles_prefix_list=$(mktemp)
operator_roles_prefix_list=$(mktemp)
oidc_id_file=$(mktemp)

function delete_resources()
{
  set +o errexit
  local operator_role
  local account_role
  local oidc_id
  while IFS= read -r operator_role
  do
    echo "Deleting ${operator_role}"
    rosa remove operator-roles -m auto -y --prefix $operator_role
  done < "$operator_roles_prefix_list"

  while IFS= read -r account_role
  do
    echo "Deleting ${account_role}"
    rosa remove account-roles -m auto -y --prefix $account_role
  done < "$account_roles_prefix_list"

  oidc_id=$(head -n 1 ${oidc_id_file})
  echo "Deleting OIDC: ${oidc_id}"
  rosa remove oidc-config -m auto -y --oidc-config-id "${oidc_id}"

  set -o errexit
}

# VPC account
export AWS_SHARED_CREDENTIALS_FILE="${CLUSTER_PROFILE_DIR}/.awscred_shared_account"
ACCOUNT_VPC_ID=$(aws --region $REGION sts get-caller-identity --output text | awk '{print $1}')

# Cluster account
export AWS_SHARED_CREDENTIALS_FILE="${CLUSTER_PROFILE_DIR}/.awscred"
ACCOUNT_CLUSTER_ID=$(aws --region $REGION sts get-caller-identity --output text | awk '{print $1}')

# ROSA Login
ROSA_TOKEN=$(cat "${CLUSTER_PROFILE_DIR}/ocm-token")
if [[ ! -z "${ROSA_TOKEN}" ]]; then
  echo "Logging into ${OCM_LOGIN_ENV} with offline token"
  rosa login --env "${OCM_LOGIN_ENV}" --token "${ROSA_TOKEN}"
  if [ $? -ne 0 ]; then
    echo "Login failed"
    exit 1
  fi
  echo "rosa-cli version:"
  rosa version
else
  echo "Cannot login! You need to specify the offline token ROSA_TOKEN!"
  exit 1
fi

OIDC_ID=$(rosa create oidc-config --mode auto -y -ojson | jq -r '.id')
if [[ "${OIDC_ID}" == "" ]] || [[ "${OIDC_ID}" == "null" ]]; then
  echo "Error: failed to create OIDC"
else
  echo "Created OIDC: ${OIDC_ID}"
  echo ${OIDC_ID} > $oidc_id_file
fi

# ---------------------------------------------------------------

PREFIX_ACCOUNT=ci-rosa-ingress-account-${RANDOM:0:3}
PREFIX_OPERATOR=ci-rosa-ingress-operator-${RANDOM:0:3}

SHARED_ROLE_ARN="arn:aws:iam::${ACCOUNT_VPC_ID}:role/dummy-shared-vpc-role"

EXPECTED_NON_SHARED_VPC_INGRESS_POLICY_STATEMENT=$(mktemp)
cat <<EOF >${EXPECTED_NON_SHARED_VPC_INGRESS_POLICY_STATEMENT}
[
  {
    "Action": [
      "elasticloadbalancing:DescribeLoadBalancers",
      "route53:ListHostedZones",
      "route53:ListTagsForResources",
      "route53:ChangeResourceRecordSets",
      "tag:GetResources"
    ],
    "Effect": "Allow",
    "Resource": "*"
  }
]
EOF

EXPECTED_SHARED_VPC_INGRESS_POLICY_STATEMENT=$(mktemp)
cat <<EOF >${EXPECTED_SHARED_VPC_INGRESS_POLICY_STATEMENT}
[
  {
    "Action": [
      "route53:ChangeResourceRecordSets"
    ],
    "Effect": "Allow",
    "Resource": "*",
    "Condition": {
      "ForAllValues:StringLike": {
        "route53:ChangeResourceRecordSetsNormalizedRecordNames": [
          "*.devshift.org",
          "*.devshiftusgov.com",
          "*.openshiftapps.com",
          "*.openshiftusgov.com"
        ]
      }
    }
  },
  {
    "Action": [
      "elasticloadbalancing:DescribeLoadBalancers",
      "route53:ListHostedZones",
      "tag:GetResources"
    ],
    "Effect": "Allow",
    "Resource": "*"
  },
  {
    "Action": "sts:AssumeRole",
    "Effect": "Allow",
    "Resource": "${SHARED_ROLE_ARN}"
  }
]
EOF

function check_policy()
{
    local region=$1
    local policy_arn=$2
    local expected_default_version=$3
    local expected_policy_statement_json_file=$4

    local ret=0
    local policy_out
    policy_out=$(mktemp)

    local default_version

    aws --region $region iam list-policy-versions --policy-arn ${policy_arn} > ${policy_out}
    default_version=$(jq -r '.Versions[] | select(.IsDefaultVersion == true) | .VersionId' ${policy_out})
    if [[ "${default_version}" != "${expected_default_version}" ]]; then
      echo "FAIL: Default version is not expected. Default version: ${default_version}, expect ${expected_default_version}"
      echo "Version list:"
      jq -r '.Versions[] | .VersionId' ${policy_out}
      ret=1
    else
      echo "PASS: Default version is ${default_version}"
    fi

    expected_policy_statement=$(jq -cr . ${expected_policy_statement_json_file} | base64 -w0)
    policy_statement=$(aws --region $region iam get-policy-version --policy-arn ${policy_arn} --version-id ${default_version} | jq -cr '.PolicyVersion.Document.Statement' | base64 -w0)

    if [[ "${policy_statement}" != "${expected_policy_statement}" ]]; then
      echo "FAIL: Policy is not expected."
      for v in $(jq -r '.Versions[] | .VersionId' ${policy_out})
      do
          echo "Version Content: ${v}"
          aws --region $region iam get-policy-version --policy-arn ${policy_arn} --version-id ${v} | jq
      done
      ret=1
    else
      echo "PASS: Policy check get passed"
    fi

    return $ret
}

# ---------------------------------------------------------------
# Test 1: Non-Shared-VPC policy upgrade to Shared-VPC role
# ---------------------------------------------------------------
account_role1=${PREFIX_ACCOUNT}1
operator_role1=${PREFIX_OPERATOR}1
installer_arn1="arn:aws:iam::${ACCOUNT_CLUSTER_ID}:role/${account_role1}-Installer-Role"
policy_name1=$(echo "${account_role1}-openshift-ingress-operator-cloud-credentials" | cut -c -64)
policy_arn1="arn:aws:iam::${ACCOUNT_CLUSTER_ID}:policy/${policy_name1}"

echo $account_role1 >> $account_roles_prefix_list
echo $operator_role1 >> $operator_roles_prefix_list

echo "POLICY CHECKING - Non-Shared-VPC policy"
rosa create account-roles -m auto -y --prefix ${account_role1}
rosa create operator-roles -m auto -y --oidc-config-id ${OIDC_ID}  --role-arn ${installer_arn1} --prefix ${operator_role1}
sleep 15
check_policy ${REGION} ${policy_arn1} "v1" $EXPECTED_NON_SHARED_VPC_INGRESS_POLICY_STATEMENT

echo "POLICY CHECKING - Non-Shared-VPC policy upgrade to Shared-VPC policy"
rosa create operator-roles -m auto -y --oidc-config-id ${OIDC_ID}  --role-arn ${installer_arn1} --prefix ${operator_role1} --shared-vpc-role-arn ${SHARED_ROLE_ARN}
sleep 15
check_policy ${REGION} ${policy_arn1} "v2" $EXPECTED_SHARED_VPC_INGRESS_POLICY_STATEMENT

# ---------------------------------------------------------------
# Test 2: Shared-VPC policy and Shared-VPC policy upgrade to Non-Shared-VPC role
# ---------------------------------------------------------------
account_role2=${PREFIX_ACCOUNT}2
operator_role2a=${PREFIX_OPERATOR}2a
operator_role2b=${PREFIX_OPERATOR}2b
installer_arn2="arn:aws:iam::${ACCOUNT_CLUSTER_ID}:role/${account_role2}-Installer-Role"

policy_name2=$(echo "${account_role2}-openshift-ingress-operator-cloud-credentials" | cut -c -64)
policy_arn2="arn:aws:iam::${ACCOUNT_CLUSTER_ID}:policy/${policy_name2}"

echo $account_role2 >> $account_roles_prefix_list
echo $operator_role2a >> $operator_roles_prefix_list
echo $operator_role2b >> $operator_roles_prefix_list

echo "POLICY CHECKING - Shared-VPC policy"
rosa create account-roles -m auto -y --prefix ${account_role2}
rosa create operator-roles -m auto -y --oidc-config-id ${OIDC_ID}  --role-arn ${installer_arn2} --prefix ${operator_role2a} --shared-vpc-role-arn ${SHARED_ROLE_ARN}
sleep 15
check_policy ${REGION} ${policy_arn2} "v1" $EXPECTED_SHARED_VPC_INGRESS_POLICY_STATEMENT

echo "POLICY CHECKING - Shared-VPC policy upgrade to Non-Shared-VPC policy"
rosa create operator-roles -m auto -y --oidc-config-id ${OIDC_ID}  --role-arn ${installer_arn2} --prefix ${operator_role2b}
sleep 15
check_policy ${REGION} ${policy_arn2} "v1" $EXPECTED_SHARED_VPC_INGRESS_POLICY_STATEMENT
