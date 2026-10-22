#!/bin/bash

set -o nounset
set -o errexit
set -o pipefail

# save the exit code for junit xml file generated in step gather-must-gather
# pre configuration steps before running installation, exit code 100 if failed,
# save to install-pre-config-status.txt
# post check steps after cluster installation, exit code 101 if failed,
# save to install-post-check-status.txt
EXIT_CODE=100
trap 'if [[ "$?" == 0 ]]; then EXIT_CODE=0; fi; echo "${EXIT_CODE}" > "${SHARED_DIR}/install-pre-config-status.txt"; CHILDREN=$(jobs -p); if test -n "${CHILDREN}"; then kill ${CHILDREN} && wait; fi' EXIT TERM

export AWS_SHARED_CREDENTIALS_FILE="${CLUSTER_PROFILE_DIR}/.awscred"

REGION="${LEASED_RESOURCE}"
CLUSTER_NAME="${NAMESPACE}-${UNIQUE_HASH}"

# version_ge returns 0 (true) if $1 >= $2 using natural version ordering.
function version_ge() {
  [[ "$1" == "$2" ]] && return 0
  [[ "$(printf '%s\n' "$2" "$1" | sort -V | head -n1)" == "$2" ]]
}

# Determine the target OCP version so version-specific permissions can be gated.
cp "${CLUSTER_PROFILE_DIR}/pull-secret" /tmp/pull-secret
oc registry login --to /tmp/pull-secret
ocp_version=$(oc adm release info --registry-config /tmp/pull-secret "${RELEASE_IMAGE_LATEST}" --output=json | jq -r '.metadata.version' | cut -d. -f 1,2)
rm -f /tmp/pull-secret
echo "Target OCP version: ${ocp_version}"

cat > ${ARTIFACT_DIR}/role_policy_doc_master.json <<EOF
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

# elasticloadbalancing:SetSecurityGroups is required on the control plane role
# from OCP 4.23/5.0 onward, where the AWS cloud controller manager manages the
# security groups attached to service load balancers. Older releases do not need
# it, so gate it by version to keep the BYO control plane policy minimal.
if version_ge "${ocp_version}" "4.23"; then
  echo "OCP ${ocp_version} >= 4.23: adding elasticloadbalancing:SetSecurityGroups to the control plane policy"
  master_policy_doc="${ARTIFACT_DIR}/role_policy_doc_master.json"
  tmp_master_policy=$(mktemp)
  jq '.Statement[0].Action += ["elasticloadbalancing:SetSecurityGroups"]' "${master_policy_doc}" > "${tmp_master_policy}"
  mv "${tmp_master_policy}" "${master_policy_doc}"
fi

cat > ${ARTIFACT_DIR}/role_policy_doc_worker.json <<EOF
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

cat > ${ARTIFACT_DIR}/default_assume_role_policy_doc.json <<EOF
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

node_types="master worker"

# Optionally create a dedicated BYO IAM role/policy for the edge compute pool
# (AWS Local/Wavelength zones).
if [[ "${PROVISION_EDGE_IAM_ROLE:-no}" == "yes" ]]; then
  cat > ${ARTIFACT_DIR}/role_policy_doc_edge.json <<EOF
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
  node_types="${node_types} edge"
fi

for node_type in ${node_types}
do
  policy_name="${CLUSTER_NAME}-byo-policy-${node_type}"
  role_name="${CLUSTER_NAME}-byo-role-${node_type}"
  policy_doc="${ARTIFACT_DIR}/role_policy_doc_${node_type}.json"

  policy_arn=$(aws --region $REGION iam create-policy --policy-name ${policy_name} --policy-document file://${policy_doc} | jq -j '.Policy.Arn')
  echo $policy_arn > ${SHARED_DIR}/aws_byo_policy_arn_${node_type}

  aws --region $REGION iam create-role --role-name ${role_name} --assume-role-policy-document file://${ARTIFACT_DIR}/default_assume_role_policy_doc.json
  echo $role_name > ${SHARED_DIR}/aws_byo_role_name_${node_type}

  aws --region $REGION iam attach-role-policy --role-name ${role_name} --policy-arn "${policy_arn}"
done
