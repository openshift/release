#!/bin/bash

set -o nounset
set -o errexit
set -o pipefail

trap 'CHILDREN=$(jobs -p); if test -n "${CHILDREN}"; then kill ${CHILDREN} && wait; fi' TERM

AWSCRED="${CLUSTER_PROFILE_DIR}/.awscred_shared_account"
if [[ -f "${AWSCRED}" ]]; then
  export AWS_SHARED_CREDENTIALS_FILE="${AWSCRED}"
else
  echo "No Shared VPC account found. Exit now"
  exit 1
fi

SAHRED_VPC_ROLE_ARN=$(head -n 1 "${SHARED_DIR}/hosted_zone_role_arn")
installer_role_arn=$(grep "Installer-Role" "${SHARED_DIR}/account-roles-arns")

principal_string="\"${installer_role_arn}\""

if [[ ${BYO_OIDC} == "true" ]]; then
  ingress_role_arn=$(grep "ingress-operator" "${SHARED_DIR}/operator-roles-arns")
  principal_string+=",\"${ingress_role_arn}\""
fi

shared_vpc_updated_trust_policy=$(mktemp)
cat > $shared_vpc_updated_trust_policy <<EOF
{
  "Version": "2012-10-17",
  "Statement": [
      {
          "Effect": "Allow",
          "Principal": {
              "AWS": [${principal_string}]
          },
          "Action": "sts:AssumeRole",
          "Condition": {}
      }
  ]
}
EOF

echo "trust policy:"
cat $shared_vpc_updated_trust_policy

aws iam update-assume-role-policy --role-name "$(echo ${SAHRED_VPC_ROLE_ARN} | cut -d '/' -f2)"  --policy-document file://${shared_vpc_updated_trust_policy}
echo "Updated Shared VPC role trust policy successfully"
  
echo "Sleeping 120s to make sure the policy is ready."
sleep 120
