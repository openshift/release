#!/bin/bash

set -o nounset
set -o errexit
set -o pipefail

trap 'CHILDREN=$(jobs -p); if test -n "${CHILDREN}"; then kill ${CHILDREN} && wait; fi' TERM
trap 'rm -rf /tmp/aws_cred_output /tmp/pull-secret /tmp/min_perms/ /tmp/jsoner.py' EXIT TERM INT


JSONER_PY="/tmp/jsoner.py"
GET_ACTIONS_PY="/tmp/get_actions.py"

function create_jsoner_py()
{
	if [[ ! -f ${JSONER_PY} ]]; then
		cat <<EOF >"${JSONER_PY}"
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
	fi
}

function create_get_actions_py()
{
	if [[ ! -f ${GET_ACTIONS_PY} ]]; then
		cat <<EOF >"${GET_ACTIONS_PY}"
import json
import sys
p = []
with open(sys.argv[1], 'r') as f:
    data = json.load(f)
    for s in data['Statement']:
        for a in s['Action']:
            if a not in p:
                p.append(a)
p.sort()
print('\n'.join(p))
EOF
	fi
}

if [ "${FIPS_ENABLED:-false}" = "true" ]; then
    export OPENSHIFT_INSTALL_SKIP_HOSTCRYPT_VALIDATION=true
fi


if [[ "${AWS_INSTALL_USE_MINIMAL_PERMISSIONS}" == "yes" ]]; then

	export AWS_SHARED_CREDENTIALS_FILE="${CLUSTER_PROFILE_DIR}/.awscred"

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

	# Do NOT change USER_POLICY_FILENAME
	#   It's the same as the output of openshift-install create permissions-policy 
	# 
	USER_POLICY_FILENAME="aws-permissions-policy-creds.json"
	USER_POLICY_FILE="${SHARED_DIR}/${USER_POLICY_FILENAME}"
	PERMISION_LIST="${ARTIFACT_DIR}/permision_list.txt"

	if ((ocp_major_version < 4 || (ocp_major_version == 4 && ocp_minor_version < 18))); then
		# There is no installer support for generating permissions prior to 4.18, so we generate one ourselves

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
iam:CreateInstanceProfile
iam:CreateRole
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

		if [[ ${CREDENTIALS_MODE} == "Mint" ]] || [[ ${CREDENTIALS_MODE} == "" ]]; then
			echo "iam:CreateAccessKey" >> "${PERMISION_LIST}"
			echo "iam:CreateUser" >> "${PERMISION_LIST}"
		fi

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
	else
		dir=/tmp/min_perms/

		mkdir -p ${dir}

		# Make a copy of the install-config.yaml since the installer will consume it.
		cp "${SHARED_DIR}/install-config.yaml" ${dir}/

		openshift-install create permissions-policy --dir ${dir}

		# Save policy to artifact dir for debugging
		mv ${dir}/${USER_POLICY_FILENAME} ${ARTIFACT_DIR}/${USER_POLICY_FILENAME}.original.json

		# AWS: the policy created by permissions-policy may exceed the 6144 limition
		# https://issues.redhat.com/browse/OCPBUGS-45612
		# Merge multi-Sid into one Sid
		create_get_actions_py
		python3 $GET_ACTIONS_PY ${ARTIFACT_DIR}/${USER_POLICY_FILENAME}.original.json > ${PERMISION_LIST}

		# A temporary workaround for shared-vpc cluster https://issues.redhat.com/browse/OCPBUGS-45807
		# If shared-vpc cluster, sts:AssumeRole permission is required.
		# the configuration of shared-vpc cluster:
		# platform:
		#   aws:
		#     hostedZone:
		#     hostedZoneRole:

		if grep -qE "hostedZone:" "${SHARED_DIR}/install-config.yaml" && grep -qE "hostedZoneRole:" "${SHARED_DIR}/install-config.yaml"; then
			echo "This is a Shared-VPC (PHZ) cluster,  adding sts:AssumeRole permission to the list."
			echo "sts:AssumeRole" >>"${PERMISION_LIST}"
		fi

		rm -rf "${dir}"
	fi

	create_jsoner_py
	
	# generate policy file and save it to shared dir so later steps have access to it.
	cat "${PERMISION_LIST}" | python3 ${JSONER_PY} >"${USER_POLICY_FILE}"

	# Save policy as a step artifact
	cp ${USER_POLICY_FILE} ${ARTIFACT_DIR}/${USER_POLICY_FILENAME}
	echo "Created policy profile ${USER_POLICY_FILE}"

else
	echo "Custom AWS user with minimal permissions is disabled for installer. Using AWS user from cluster profile."
fi



if [[ "${AWS_CCOCTL_USE_MINIMAL_PERMISSIONS}" == "yes" ]]; then

	USER_POLICY_FILENAME="aws-permissions-policy-creds-ccoctl.json"
	USER_POLICY_FILE="${SHARED_DIR}/${USER_POLICY_FILENAME}"

	PERMISION_LIST="${ARTIFACT_DIR}/permision_list_ccoctl.txt"
	cat <<EOF > "${PERMISION_LIST}"
cloudfront:ListCloudFrontOriginAccessIdentities
cloudfront:ListDistributions
cloudfront:ListTagsForResource
iam:CreateOpenIDConnectProvider
iam:CreateRole
iam:DeleteOpenIDConnectProvider
iam:DeleteRole
iam:DeleteRolePolicy
iam:GetOpenIDConnectProvider
iam:GetRole
iam:GetUser
iam:ListOpenIDConnectProviders
iam:ListRolePolicies
iam:ListRoles
iam:PutRolePolicy
iam:TagOpenIDConnectProvider
iam:TagRole
s3:CreateBucket
s3:DeleteBucket
s3:DeleteObject
s3:GetBucketAcl
s3:GetBucketTagging
s3:GetObject
s3:GetObjectAcl
s3:GetObjectTagging
s3:ListBucket
s3:PutBucketAcl
s3:PutBucketPolicy
s3:PutBucketPublicAccessBlock
s3:PutBucketTagging
s3:PutObject
s3:PutObjectAcl
s3:PutObjectTagging
EOF
	if [[ "${STS_USE_PRIVATE_S3}" == "yes" ]]; then
		# enable option --create-private-s3-bucket
		echo "cloudfront:CreateCloudFrontOriginAccessIdentity" >> "${PERMISION_LIST}"
		echo "cloudfront:CreateDistribution" >> "${PERMISION_LIST}"
		echo "cloudfront:DeleteCloudFrontOriginAccessIdentity" >> "${PERMISION_LIST}"
		echo "cloudfront:DeleteDistribution" >> "${PERMISION_LIST}"
		echo "cloudfront:GetCloudFrontOriginAccessIdentity" >> "${PERMISION_LIST}"
		echo "cloudfront:GetCloudFrontOriginAccessIdentityConfig" >> "${PERMISION_LIST}"
		echo "cloudfront:GetDistribution" >> "${PERMISION_LIST}"
		echo "cloudfront:TagResource" >> "${PERMISION_LIST}"
		echo "cloudfront:UpdateDistribution" >> "${PERMISION_LIST}"
  	fi

	create_jsoner_py
	# generate policy file
	cat "${PERMISION_LIST}" | python3 ${JSONER_PY} >"${USER_POLICY_FILE}"
	echo "Created policy profile ${USER_POLICY_FILE}"
else
	echo "Custom AWS user with minimal permissions is disabled for ccoctl tool. Using AWS user from cluster profile."
fi
