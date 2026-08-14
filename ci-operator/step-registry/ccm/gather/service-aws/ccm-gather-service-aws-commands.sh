#!/bin/bash

#
#  ccm-gather-service-aws step collects Load Balancer information from AWS API.
#

set -o nounset
set -o errexit
set -o pipefail

if test ! -f "${KUBECONFIG}"
then
	echo "No kubeconfig, so no point in calling ccm-gather-service-aws."
	exit 0
fi

if ! command -v aws &>/dev/null; then
	echo "AWS CLI not found, skipping..."
	exit 0
fi

if test ! -f "${CLUSTER_PROFILE_DIR}/.awscred"; then
	echo "No AWS credentials, skipping..."
	exit 0
fi

export AWS_SHARED_CREDENTIALS_FILE=${CLUSTER_PROFILE_DIR}/.awscred
export AWS_REGION=${LEASED_RESOURCE}

function gather_lb_info_for_service() {
	local service_name=$1
	local namespace=$2
	local artifact_file="${ARTIFACT_DIR}/${namespace}-${service_name}-loadbalancer.json"

	echo "Gathering Service LoadBalancer Hostname of ${namespace}/${service_name} service..."

	# Extracts the LB name inferred from the DNS Name of the service.
	# AWS standard format is <LB_NAME>-<random-string>.<REGION>.elb.amazonaws.com for Classic Load Balancers,
	# and <LB_NAME>-<random-string>.elb.<REGION>.amazonaws.com for Network Load Balancers. Examples:
	# For LB_DNS=ad8c6af0820cc462c90934cd3545b5db-3a0f596def7c2ca6.elb.us-east-1.amazonaws.com, LB_NAME=ad8c6af0820cc462c90934cd3545b5db
	# For LB_DNS=a3e99bc98a38549e29a699c5f9079bc9-1408355316.us-east-1.elb.amazonaws.com, LB_NAME=a3e99bc98a38549e29a699c5f9079bc9
	# For LB_DNS=mrb-v46-4vp9c-ext-6c9f52b5e9195fd4.elb.us-east-1.amazonaws.com, LB_NAME=mrb-v46-4vp9c-ext
	LB_DNS=$(oc get svc/"${service_name}" -n "${namespace}" -o jsonpath='{.status.loadBalancer.ingress[0].hostname}')
	LB_NAME=$(echo $LB_DNS | sed -e 's/\..*//' -e 's/-[^-]*$//')

	echo "Service (${namespace}/${service_name}): LoadBalancer Name=${LB_NAME} Hostname=${LB_DNS}"

	# CLB lookup
	{
		if aws elb describe-load-balancers --load-balancer-names $LB_NAME \
			--query 'LoadBalancerDescriptions[0].{LoadBalancerName:LoadBalancerName,DNSName:DNSName,CreatedTime:CreatedTime,AvailabilityZones:AvailabilityZones,SecurityGroups:SecurityGroups,IpAddressType:IpAddressType,Scheme:Scheme}' \
			--output json | jq '. + {Type: "Classic"}' > /tmp/output_clb.json; then
			echo "CLB found for LoadBalancer Name=${LB_NAME}, saving to ${artifact_file}"
			cat /tmp/output_clb.json >> "${artifact_file}"
		else
			echo "No CLB found for LoadBalancer Name=${LB_NAME}"
		fi
	} || true

	# NLB lookup
	{
		if aws elbv2 describe-load-balancers --names $LB_NAME \
			--query 'LoadBalancers[0].{DNSName:DNSName,CreatedTime:CreatedTime,LoadBalancerName:LoadBalancerName,State:State,Type:Type,AvailabilityZones:AvailabilityZones,SecurityGroups:SecurityGroups,IpAddressType:IpAddressType,Scheme:Scheme}' \
			> /tmp/output_nlb.json; then
			echo "NLB found for LoadBalancer Name=${LB_NAME}, saving to ${artifact_file}"
			cat /tmp/output_nlb.json >> "${artifact_file}"
		else
			echo "No NLB found for LoadBalancer Name=${LB_NAME}"
		fi
	} || true
}

# Discovery the Load Balancer hostname of default ingresscontroller service and
# remove the domain from the hostname and AWS-appended random string to get the load balancer name
gather_lb_info_for_service "router-default" "openshift-ingress"