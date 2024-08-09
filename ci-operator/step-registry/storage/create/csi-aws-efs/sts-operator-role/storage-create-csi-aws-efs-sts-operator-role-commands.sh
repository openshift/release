#!/bin/bash
set -o errexit
set -o nounset
set -o pipefail

export AWS_SHARED_CREDENTIALS_FILE="${CLUSTER_PROFILE_DIR}/.awscred"

# For disconnected or otherwise unreachable environments, we want to
# have steps use an HTTP(S) proxy to reach the API server. This proxy
# configuration file should export HTTP_PROXY, HTTPS_PROXY, and NO_PROXY
# environment variables, as well as their lowercase equivalents (note
# that libcurl doesn't recognize the uppercase variables).
if test -f "${SHARED_DIR}/proxy-conf.sh"
then
	# shellcheck disable=SC1090
	source "${SHARED_DIR}/proxy-conf.sh"
fi

AWS_ACCOUNT_ID=$(aws sts get-caller-identity --query "Account" --output text)
CLUSTER_ID=$(oc get infrastructure cluster -ojsonpath='{.status.infrastructureName}')
OIDC_PROVIDER=$(oc get authentication cluster -ojsonpath='{.spec.serviceAccountIssuer}' | sed -e "s/^https:\/\///")
NAMESPACE="openshift-cluster-csi-drivers"
POLICY_ARN_STRINGS="arn:aws:iam::aws:policy/AmazonS3FullAccess
arn:aws:iam::aws:policy/AmazonElasticFileSystemFullAccess"
ROLE_NAME=${CLUSTER_ID}"-efs-operator-role"


echo "Create efs csi driver operator role"

cat > ${SHARED_DIR}/trust.json <<EOF
{
  "Version": "2012-10-17",
  "Statement": [
    {
      "Effect": "Allow",
      "Principal": {
        "Federated": "arn:aws:iam::${AWS_ACCOUNT_ID}:oidc-provider/${OIDC_PROVIDER}"
      },
      "Action": "sts:AssumeRoleWithWebIdentity",
      "Condition": {
        "StringEquals": {
          "${OIDC_PROVIDER}:sub": [
            "system:serviceaccount:${NAMESPACE}:aws-efs-csi-driver-operator",
            "system:serviceaccount:${NAMESPACE}:aws-efs-csi-driver-controller-sa"
          ]
        }
      }
    }
  ]
}
EOF

aws iam create-role --role-name "$ROLE_NAME" --assume-role-policy-document file://${SHARED_DIR}/trust.json --description "Role for efs operator" --tags Key=kubernetes.io/cluster/${CLUSTER_ID},Value=owned --output text

echo "Attach policies to efs csi driver operator role"
while IFS= read -r POLICY_ARN; do
   aws iam attach-role-policy \
       --role-name "$ROLE_NAME" \
       --policy-arn "${POLICY_ARN}"
   echo "INFO: Attach $POLICY_ARN to operator role done..."
done <<< "$POLICY_ARN_STRINGS"

echo "arn:aws:iam::${AWS_ACCOUNT_ID}:role/${ROLE_NAME}"  > ${SHARED_DIR}/efs-csi-driver-operator-role-arn
