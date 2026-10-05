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
	# shellcheck disable=SC1091
	source "${SHARED_DIR}/proxy-conf.sh"
fi

AWS_ACCOUNT_ID=$(aws sts get-caller-identity --query "Account" --output text)
CLUSTER_ID=$(oc get infrastructure cluster -o jsonpath='{.status.infrastructureName}')
OIDC_PROVIDER=$(oc get authentication cluster -o jsonpath='{.spec.serviceAccountIssuer}' | sed -e "s/^https:\/\///")
NAMESPACE="openshift-cluster-csi-drivers"
ROLE_NAME=${CLUSTER_ID}"-efs-operator-role"
AWS_EFS_CSI_DRIVER_CONTROLLER_POLICY_NAME="${CLUSTER_ID}-aws-efs-csi-driver-controller-policy"

# logger function prints standard logs
logger() {
    local level="$1"
    local message="$2"
    local timestamp

    # Generate a timestamp for the log entry
    timestamp=$(date +"%Y-%m-%d %H:%M:%S")

    # Print the log message with the level and timestamp
    echo "[$timestamp] [$level] $message"
}

# Ref: https://docs.openshift.com/rosa/storage/container_storage_interface/persistent-storage-csi-aws-efs.html
logger "INFO" "Create efs csi driver operator role"

cat > "${SHARED_DIR}"/aws-efs-csi-driver-operator-trust.json <<EOF
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

cat > "${SHARED_DIR}"/efs-csi-driver-controller-policy.json <<EOF
{
  "Version": "2012-10-17",
  "Statement": [
    {
      "Effect": "Allow",
      "Action": [
        "elasticfilesystem:DescribeAccessPoints",
        "elasticfilesystem:DescribeFileSystems",
        "elasticfilesystem:DescribeMountTargets",
        "ec2:DescribeAvailabilityZones",
        "elasticfilesystem:TagResource"
      ],
      "Resource": "*"
    },
    {
      "Effect": "Allow",
      "Action": [
        "elasticfilesystem:CreateAccessPoint"
      ],
      "Resource": "*",
      "Condition": {
        "StringLike": {
          "aws:RequestTag/efs.csi.aws.com/cluster": "true"
        }
      }
    },
    {
      "Effect": "Allow",
      "Action": "elasticfilesystem:DeleteAccessPoint",
      "Resource": "*",
      "Condition": {
        "StringEquals": {
          "aws:ResourceTag/efs.csi.aws.com/cluster": "true"
        }
      }
    }
  ]
}
EOF

ROLE_ARN=$(aws iam create-role \
  --role-name "$ROLE_NAME" \
  --assume-role-policy-document file://"${SHARED_DIR}"/aws-efs-csi-driver-operator-trust.json \
  --description "Role for efs operator" \
  --tags Key=kubernetes.io/cluster/"${CLUSTER_ID}",Value=owned \
  --query "Role.Arn" --output text)
logger "INFO" "aws-efs-csi-driver-operator role $ROLE_ARN created ..."

POLICY_ARN=$(aws iam create-policy \
  --policy-name "${AWS_EFS_CSI_DRIVER_CONTROLLER_POLICY_NAME}" \
  --policy-document file://"${SHARED_DIR}"/efs-csi-driver-controller-policy.json \
  --tags Key=kubernetes.io/cluster/"${CLUSTER_ID}",Value=owned \
  --query 'Policy.Arn' --output text)
logger "INFO" "aws-efs-csi-driver-policy $POLICY_ARN created ..."

aws iam attach-role-policy \
    --role-name "${ROLE_NAME}" \
    --policy-arn "${POLICY_ARN}"
logger "INFO" "Attach $POLICY_ARN to operator role done..."

echo "$ROLE_ARN"  > "${SHARED_DIR}"/efs-csi-driver-operator-role-arn
