#!/bin/bash

#
#  ccm-check-service-aws step checks Load Balancer information from AWS API.
#

set -o nounset
set -o errexit
set -o pipefail

if test ! -f "${KUBECONFIG}"
then
	echo "No kubeconfig, so no point in calling ccm-check-service-aws."
	exit 0
fi

if ! command -v aws &> /dev/null
then
    echo "$(date -u --rfc-3339=seconds) - Install AWS cli..."
    export PATH="${HOME}/.local/bin:${PATH}" 

    if [ "$(python -c 'import sys;print(sys.version_info.major)')" -eq 2 ]
    then
      easy_install --user 'pip<21'
      pip install --user awscli
    elif [ "$(python -c 'import sys;print(sys.version_info.major)')" -eq 3 ]
    then
      python -m ensurepip
      if command -v pip3 &> /dev/null
      then        
        pip3 install --user awscli
      elif command -v pip &> /dev/null
      then
        pip install --user awscli
      fi
    else    
      echo "$(date -u --rfc-3339=seconds) - No pip available exiting..."
      exit 1
    fi
fi

if test ! -f "${CLUSTER_PROFILE_DIR}/.awscred"; then
	echo "No AWS credentials, skipping..."
	exit 0
fi

if [ -f "${SHARED_DIR}/kubeconfig" ] ; then
    export KUBECONFIG=${SHARED_DIR}/kubeconfig
fi

if [ -f "${SHARED_DIR}/proxy-conf.sh" ] ; then
    source "${SHARED_DIR}/proxy-conf.sh"
fi

export AWS_SHARED_CREDENTIALS_FILE=${CLUSTER_PROFILE_DIR}/.awscred
export AWS_REGION=${LEASED_RESOURCE}
export AWS_DEFAULT_REGION=${LEASED_RESOURCE}

function check_lb_info_for_service() {
	local service_name=$1
	local namespace=$2

	echo "$(date -u --rfc-3339=seconds) - Checking Service LoadBalancer Hostname of ${namespace}/${service_name} service..."

	# Extracts the LB name inferred from the DNS Name of the service.
	# AWS standard format is <LB_NAME>-<random-string>.<REGION>.elb.amazonaws.com for Classic Load Balancers,
	# and <LB_NAME>-<random-string>.elb.<REGION>.amazonaws.com for Network Load Balancers. Examples:
	# For LB_DNS=ad8c6af0820cc462c90934cd3545b5db-3a0f596def7c2ca6.elb.us-east-1.amazonaws.com, LB_NAME=ad8c6af0820cc462c90934cd3545b5db
	# For LB_DNS=a3e99bc98a38549e29a699c5f9079bc9-1408355316.us-east-1.elb.amazonaws.com, LB_NAME=a3e99bc98a38549e29a699c5f9079bc9
	# For LB_DNS=mrb-v46-4vp9c-ext-6c9f52b5e9195fd4.elb.us-east-1.amazonaws.com, LB_NAME=mrb-v46-4vp9c-ext
	LB_DNS=$(oc get svc/"${service_name}" -n "${namespace}" -o jsonpath='{.status.loadBalancer.ingress[0].hostname}')
	LB_NAME=$(echo $LB_DNS | sed -e 's/\..*//' -e 's/-[^-]*$//')

	echo "Service (${namespace}/${service_name}): LoadBalancer Name=${LB_NAME} Hostname=${LB_DNS}"

  	# Get Service ports
	echo "$(date -u --rfc-3339=seconds) - Get Service ports..."
  	SVC_PORTS=$(oc get svc "${service_name}" -n "${namespace}" -o jsonpath='{.spec.ports[*].port}' 2>/dev/null)

  	if [ -z "$SVC_PORTS" ]; then
    	echo "Error: Service '${service_name}' not found in namespace '${namespace}'"
    	exit 1
  	fi

  	echo "Service ports: $SVC_PORTS"

	# Check type
	echo "$(date -u --rfc-3339=seconds) - Check LoadBalancer type..."
  	LB_TYPE=$(aws elbv2 describe-load-balancers \
    	--names "$LB_NAME" \
    	--query 'LoadBalancers[0].Type' \
   	 	--output text)

  	if [ "$LB_TYPE" != "network" ]; then
    	echo "Error: Load balancer type is '$LB_TYPE', not 'network'. Exiting."
    	exit 1
  	fi

	echo "Type is $LB_TYPE"

  	# Check security groups
	echo "$(date -u --rfc-3339=seconds) - Check LoadBalancer security groups..."
  	SG_IDS=$(aws elbv2 describe-load-balancers \
    	--names "$LB_NAME" \
    	--query 'LoadBalancers[0].SecurityGroups[]' \
    	--output text)

	if [ -z "$SG_IDS" ] || [ "$SG_IDS" = "None" ]; then
    	echo "Error: No security groups found. Exiting."
    	exit 1
  	fi

  	echo "Security groups: $SG_IDS"

	aws ec2 describe-security-groups \
    	--group-ids $SG_IDS \
    	--query 'SecurityGroups[].[GroupId,GroupName]' \
    	--output text | while read -r SG_ID SG_NAME; do
      echo "  - $SG_ID ($SG_NAME)"
  	done

	# Check ports
	echo "$(date -u --rfc-3339=seconds) - Check security groups rules..."
  	for port in $SVC_PORTS; do
    	ALLOWED=$(aws ec2 describe-security-groups \
      	--group-ids $SG_IDS \
      	--filters "Name=ip-permission.from-port,Values=$port" "Name=ip-permission.to-port,Values=$port" \
      	--query 'SecurityGroups[0].GroupId' \
      	--output text)

    	if [ -z "$ALLOWED" ] || [ "$ALLOWED" = "None" ]; then
      		echo "Port $port NOT allowed"
      		exit 1
    	else
      		echo "Port $port allowed"
    	fi
  	done

  	echo "All ports allowed"
}

# Discovery the Load Balancer hostname of default ingresscontroller service and
# remove the domain from the hostname and AWS-appended random string to get the load balancer name
check_lb_info_for_service "router-default" "openshift-ingress"
