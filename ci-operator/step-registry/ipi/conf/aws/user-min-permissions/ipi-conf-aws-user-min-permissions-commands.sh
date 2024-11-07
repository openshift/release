#!/bin/bash

set -o nounset
set -o errexit
set -o pipefail

trap 'CHILDREN=$(jobs -p); if test -n "${CHILDREN}"; then kill ${CHILDREN} && wait; fi' TERM
trap 'rm -rf /tmp/aws_cred_output /tmp/pull-secret /tmp/min_perms/ /tmp/jsoner.py' EXIT TERM INT

USER_POLICY_FILENAME="aws-permissions-policy-creds.json"
USER_POLICY_FILE="${SHARED_DIR}/${USER_POLICY_FILENAME}"

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
ocp_version=$(oc adm release info --registry-config /tmp/pull-secret ${RELEASE_IMAGE_INSTALL} -ojsonpath='{.metadata.version}' | cut -d. -f 1,2)
ocp_major_version=$(echo "${ocp_version}" | awk --field-separator=. '{print $1}')
ocp_minor_version=$(echo "${ocp_version}" | awk --field-separator=. '{print $2}')
rm /tmp/pull-secret

export AWS_SHARED_CREDENTIALS_FILE="${CLUSTER_PROFILE_DIR}/.awscred"

if ((ocp_major_version < 4 || (ocp_major_version == 4 && ocp_minor_version < 18))); then
	# There is no installer support for generating permissions prior to 4.18, so we generate one ourselves
	PERMISION_LIST="${ARTIFACT_DIR}/permision_list.txt"

	cat <<EOF >"${PERMISION_LIST}"
autoscaling:DescribeAutoScalingGroups
ec2:AllocateAddress
ec2:AssociateAddress
ec2:AssociateDhcpOptions
ec2:AssociateRouteTable
ec2:AttachInternetGateway
ec2:AttachNetworkInterface
ec2:AuthorizeSecurityGroupEgress
ec2:AuthorizeSecurityGroupIngress
ec2:CopyImage
ec2:CreateDhcpOptions
ec2:CreateInternetGateway
ec2:CreateNatGateway
ec2:CreateNetworkInterface
ec2:CreateRoute
ec2:CreateRouteTable
ec2:CreateSecurityGroup
ec2:CreateSubnet
ec2:CreateTags
ec2:CreateVolume
ec2:CreateVpc
ec2:CreateVpcEndpoint
ec2:DeleteDhcpOptions
ec2:DeleteInternetGateway
ec2:DeleteNatGateway
ec2:DeleteNetworkInterface
ec2:DeleteRoute
ec2:DeleteRouteTable
ec2:DeleteSecurityGroup
ec2:DeleteSnapshot
ec2:DeleteSubnet
ec2:DeleteTags
ec2:DeleteVolume
ec2:DeleteVpc
ec2:DeleteVpcEndpoints
ec2:DeregisterImage
ec2:DescribeAccountAttributes
ec2:DescribeAddresses
ec2:DescribeAvailabilityZones
ec2:DescribeDhcpOptions
ec2:DescribeImages
ec2:DescribeInstanceAttribute
ec2:DescribeInstanceCreditSpecifications
ec2:DescribeInstances
ec2:DescribeInstanceTypeOfferings
ec2:DescribeInstanceTypes
ec2:DescribeInternetGateways
ec2:DescribeKeyPairs
ec2:DescribeNatGateways
ec2:DescribeNetworkAcls
ec2:DescribeNetworkInterfaces
ec2:DescribePrefixLists
ec2:DescribeRegions
ec2:DescribeRouteTables
ec2:DescribeSecurityGroups
ec2:DescribeSubnets
ec2:DescribeTags
ec2:DescribeVolumes
ec2:DescribeVpcAttribute
ec2:DescribeVpcClassicLink
ec2:DescribeVpcClassicLinkDnsSupport
ec2:DescribeVpcEndpoints
ec2:DescribeVpcs
ec2:DetachInternetGateway
ec2:DisassociateRouteTable
ec2:GetEbsDefaultKmsKeyId
ec2:ModifyInstanceAttribute
ec2:ModifyNetworkInterfaceAttribute
ec2:ModifySubnetAttribute
ec2:ModifyVpcAttribute
ec2:ReleaseAddress
ec2:ReplaceRouteTableAssociation
ec2:RevokeSecurityGroupEgress
ec2:RevokeSecurityGroupIngress
ec2:RunInstances
ec2:TerminateInstances
elasticloadbalancing:AddTags
elasticloadbalancing:ApplySecurityGroupsToLoadBalancer
elasticloadbalancing:AttachLoadBalancerToSubnets
elasticloadbalancing:ConfigureHealthCheck
elasticloadbalancing:CreateListener
elasticloadbalancing:CreateLoadBalancer
elasticloadbalancing:CreateLoadBalancerListeners
elasticloadbalancing:CreateTargetGroup
elasticloadbalancing:DeleteLoadBalancer
elasticloadbalancing:DeleteTargetGroup
elasticloadbalancing:DeregisterInstancesFromLoadBalancer
elasticloadbalancing:DeregisterTargets
elasticloadbalancing:DescribeInstanceHealth
elasticloadbalancing:DescribeListeners
elasticloadbalancing:DescribeLoadBalancerAttributes
elasticloadbalancing:DescribeLoadBalancers
elasticloadbalancing:DescribeTags
elasticloadbalancing:DescribeTargetGroupAttributes
elasticloadbalancing:DescribeTargetGroups
elasticloadbalancing:DescribeTargetHealth
elasticloadbalancing:ModifyLoadBalancerAttributes
elasticloadbalancing:ModifyTargetGroup
elasticloadbalancing:ModifyTargetGroupAttributes
elasticloadbalancing:RegisterInstancesWithLoadBalancer
elasticloadbalancing:RegisterTargets
elasticloadbalancing:SetLoadBalancerPoliciesOfListener
iam:AddRoleToInstanceProfile
iam:CreateAccessKey
iam:CreateInstanceProfile
iam:CreateRole
iam:CreateUser
iam:DeleteAccessKey
iam:DeleteInstanceProfile
iam:DeleteRole
iam:DeleteRolePolicy
iam:DeleteUser
iam:DeleteUserPolicy
iam:GetInstanceProfile
iam:GetRole
iam:GetRolePolicy
iam:GetUser
iam:GetUserPolicy
iam:ListAccessKeys
iam:ListAttachedRolePolicies
iam:ListInstanceProfiles
iam:ListInstanceProfilesForRole
iam:ListRolePolicies
iam:ListRoles
iam:ListUserPolicies
iam:ListUsers
iam:PassRole
iam:PutRolePolicy
iam:PutUserPolicy
iam:RemoveRoleFromInstanceProfile
iam:SimulatePrincipalPolicy
iam:TagRole
iam:TagUser
iam:UntagRole
route53:ChangeResourceRecordSets
route53:ChangeTagsForResource
route53:CreateHostedZone
route53:DeleteHostedZone
route53:GetChange
route53:GetHostedZone
route53:ListHostedZones
route53:ListHostedZonesByName
route53:ListResourceRecordSets
route53:ListTagsForResource
route53:UpdateHostedZoneComment
s3:AbortMultipartUpload
s3:CreateBucket
s3:DeleteBucket
s3:DeleteObject
s3:GetAccelerateConfiguration
s3:GetBucketAcl
s3:GetBucketCors
s3:GetBucketLocation
s3:GetBucketLogging
s3:GetBucketObjectLockConfiguration
s3:GetBucketPublicAccessBlock
s3:GetBucketReplication
s3:GetBucketRequestPayment
s3:GetBucketTagging
s3:GetBucketVersioning
s3:GetBucketWebsite
s3:GetEncryptionConfiguration
s3:GetLifecycleConfiguration
s3:GetObject
s3:GetObjectAcl
s3:GetObjectTagging
s3:GetObjectVersion
s3:GetReplicationConfiguration
s3:HeadBucket
s3:ListBucket
s3:ListBucketMultipartUploads
s3:ListBucketVersions
s3:PutBucketAcl
s3:PutBucketPublicAccessBlock
s3:PutBucketTagging
s3:PutEncryptionConfiguration
s3:PutLifecycleConfiguration
s3:PutObject
s3:PutObjectAcl
s3:PutObjectTagging
servicequotas:ListAWSDefaultServiceQuotas
tag:GetResources
EOF
	# additional permisions for 4.11+
	if ((ocp_minor_version >= 11 && ocp_major_version == 4)); then
		echo "ec2:DeletePlacementGroup" >>"${PERMISION_LIST}"
		echo "s3:GetBucketPolicy" >>"${PERMISION_LIST}"
	fi

	# additional permisions for 4.14+
	if ((ocp_minor_version >= 14 && ocp_major_version == 4)); then
		echo "ec2:DescribeSecurityGroupRules" >>"${PERMISION_LIST}"

		# sts:AssumeRole is required for Shared-VPC install https://issues.redhat.com/browse/OCPBUGS-17751
		echo "sts:AssumeRole" >>"${PERMISION_LIST}"
	fi

	# additional permisions for 4.15+
	if ((ocp_minor_version >= 15 && ocp_major_version == 4)); then
		echo "iam:TagInstanceProfile" >>"${PERMISION_LIST}"
	fi

	# additional permisions for 4.16+
	if ((ocp_minor_version >= 16 && ocp_major_version == 4)); then
		echo "ec2:DisassociateAddress" >>"${PERMISION_LIST}"
		echo "elasticloadbalancing:SetSecurityGroups" >>"${PERMISION_LIST}"
		echo "s3:PutBucketPolicy" >>"${PERMISION_LIST}"
	fi

	cat <<EOF >"/tmp/jsoner.py"
import json
import sys

data = sys.stdin.read().splitlines()
out = {
	"Version": "2012-10-17",
	"Statement": [{
		"Effect": "Allow",
		"Resource": "*",
		"Action": data,
	}]
}
print(json.dumps(out, indent=2))
EOF
	# generate policy file
	cat "${PERMISION_LIST}" | python3 /tmp/jsoner.py >"${USER_POLICY_FILE}"
	rm -f /tmp/jsoner.py

else
	dir=/tmp/min_perms/

	mkdir -p ${dir}

	# Make a copy of the install-config.yaml since the installer will consume it.
	cp "${SHARED_DIR}/install-config.yaml" ${dir}/

	openshift-install create permissions-policy --dir ${dir}

	# Save policy to shared dir so later steps have access to it.
	mv ${dir}/${USER_POLICY_FILENAME} ${USER_POLICY_FILE}

	rm -rf "${dir}"
fi

# Save policy as a step artifact
cp ${USER_POLICY_FILE} ${ARTIFACT_DIR}/${USER_POLICY_FILENAME}
