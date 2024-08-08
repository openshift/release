#!/bin/bash

set -o nounset
set -o errexit
set -o pipefail

trap 'CHILDREN=$(jobs -p); if test -n "${CHILDREN}"; then kill ${CHILDREN} && wait; fi' TERM

export AWS_SHARED_CREDENTIALS_FILE="${CLUSTER_PROFILE_DIR}/.awscred"

REGION="${LEASED_RESOURCE}"
CLUSTER_NAME="${NAMESPACE}-${UNIQUE_HASH}"

cat >${ARTIFACT_DIR}/role_policy_doc_master.json <<EOF
{
    "Version": "2012-10-17",
    "Statement": [
        {
            "Action": [
                "ec2:AttachVolume",
                "ec2:AuthorizeSecurityGroupIngress",
                "ec2:CreateSecurityGroup",
                "ec2:CreateTags",
                "ec2:CreateVolume",
                "ec2:DeleteSecurityGroup",
                "ec2:DeleteVolume",
                "ec2:Describe*",
                "ec2:DetachVolume",
                "ec2:ModifyInstanceAttribute",
                "ec2:ModifyVolume",
                "ec2:RevokeSecurityGroupIngress",
                "elasticloadbalancing:AddTags",
                "elasticloadbalancing:AttachLoadBalancerToSubnets",
                "elasticloadbalancing:ApplySecurityGroupsToLoadBalancer",
                "elasticloadbalancing:CreateListener",
                "elasticloadbalancing:CreateLoadBalancer",
                "elasticloadbalancing:CreateLoadBalancerPolicy",
                "elasticloadbalancing:CreateLoadBalancerListeners",
                "elasticloadbalancing:CreateTargetGroup",
                "elasticloadbalancing:ConfigureHealthCheck",
                "elasticloadbalancing:DeleteListener",
                "elasticloadbalancing:DeleteLoadBalancer",
                "elasticloadbalancing:DeleteLoadBalancerListeners",
                "elasticloadbalancing:DeleteTargetGroup",
                "elasticloadbalancing:DeregisterInstancesFromLoadBalancer",
                "elasticloadbalancing:DeregisterTargets",
                "elasticloadbalancing:Describe*",
                "elasticloadbalancing:DetachLoadBalancerFromSubnets",
                "elasticloadbalancing:ModifyListener",
                "elasticloadbalancing:ModifyLoadBalancerAttributes",
                "elasticloadbalancing:ModifyTargetGroup",
                "elasticloadbalancing:ModifyTargetGroupAttributes",
                "elasticloadbalancing:RegisterInstancesWithLoadBalancer",
                "elasticloadbalancing:RegisterTargets",
                "elasticloadbalancing:SetLoadBalancerPoliciesForBackendServer",
                "elasticloadbalancing:SetLoadBalancerPoliciesOfListener",
                "kms:DescribeKey"
            ],
            "Resource": "*",
            "Effect": "Allow"
        }
    ]
}
EOF

cat >${ARTIFACT_DIR}/role_policy_doc_worker.json <<EOF
{
    "Version": "2012-10-17",
    "Statement": [
        {
            "Effect": "Allow",
            "Action": [
                "ec2:DescribeInstances",
                "ec2:DescribeRegions"
            ],
            "Resource": "*"
        }
    ]
}
EOF

cat >${ARTIFACT_DIR}/default_assume_role_policy_doc.json <<EOF
{
  "Version": "2012-10-17",
  "Statement": [
    {
      "Effect": "Allow",
      "Principal": {
        "Service": "ec2.amazonaws.com"
      },
      "Action": "sts:AssumeRole"
    }
  ]
}
EOF

for node_type in master worker; do
	policy_name="${CLUSTER_NAME}-byo-policy-${node_type}"
	role_name="${CLUSTER_NAME}-byo-role-${node_type}"
	profile_name="${CLUSTER_NAME}-byo-profile-${node_type}"
	policy_doc="${ARTIFACT_DIR}/role_policy_doc_${node_type}.json"

	policy_arn=$(aws --region $REGION iam create-policy --policy-name ${policy_name} --policy-document file://${policy_doc} | jq -j '.Policy.Arn')
	echo $policy_arn >${SHARED_DIR}/aws_byo_policy_arn_${node_type}

	aws --region $REGION iam create-role --role-name ${role_name} --assume-role-policy-document file://${ARTIFACT_DIR}/default_assume_role_policy_doc.json
	echo $role_name >${SHARED_DIR}/aws_byo_role_name_${node_type}

	aws --region $REGION iam attach-role-policy --role-name ${role_name} --policy-arn "${policy_arn}"

	aws --region $REGION iam create-instance-profile --instance-profile-name ${profile_name}
	aws --region $REGION iam add-role-to-instance-profile --instance-profile-name ${profile_name} --role-name ${role_name}
	echo $profile_name >${SHARED_DIR}/aws_byo_profile_name_${node_type}
done
