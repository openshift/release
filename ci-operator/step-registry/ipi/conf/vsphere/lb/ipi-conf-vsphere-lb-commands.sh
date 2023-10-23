#!/bin/bash

set -o nounset
set -o errexit
set -o pipefail

# notes: jcallen: no more VMC....should we just delete this??????

# Continue iff this is a launch job
if [ "${JOB_NAME_SAFE}" != "launch" ]; then
  echo "Skipping Load Balancer setup."
  exit 0
fi

# If this is a `launch` and we are in the multi-zone range, we also
# dont want to configure the load balancer
if [ $((${LEASED_RESOURCE//[!0-9]/})) -ge 151 ]; then
  if [ $((${LEASED_RESOURCE//[!0-9]/})) -le 154 ]; then
    echo "Multi-zone installation range."
    exit 0
  fi
fi

export AWS_DEFAULT_REGION=us-west-2 # TODO: Derive this?
export AWS_SHARED_CREDENTIALS_FILE=/var/run/vault/vsphere/.awscred
export AWS_MAX_ATTEMPTS=50
export AWS_RETRY_MODE=adaptive
export HOME=/tmp

if ! command -v aws &>/dev/null; then
  echo "$(date -u --rfc-3339=seconds) - Install AWS cli..."
  export PATH="${HOME}/.local/bin:${PATH}"
  if command -v pip3 &>/dev/null; then
    pip3 install --user awscli
  else
    if [ "$(python -c 'import sys;print(sys.version_info.major)')" -eq 2 ]; then
      easy_install --user 'pip<21'
      pip install --user awscli
    else
      echo "$(date -u --rfc-3339=seconds) - No pip available exiting..."
      exit 1
    fi
  fi
fi

cluster_name=${NAMESPACE}-${UNIQUE_HASH}

# Load array created in setup-vips:
# 0: API
# 1: Ingress
declare -a vips
mapfile -t vips <"${SHARED_DIR}"/vips.txt

# Create Network Load Balancer in the subnet that is routable into VMC network
vpc_id=$(aws ec2 describe-vpcs --filters Name=tag:"aws:cloudformation:stack-name",Values=vsphere-vpc --query 'Vpcs[0].VpcId' --output text)
vmc_subnet="subnet-011c2a9515cdc7ef7" # TODO: Derive this?

echo "Creating Network Load Balancer..."

nlb_arn=$(aws elbv2 create-load-balancer --name ${cluster_name} --subnets ${vmc_subnet} --type network --query 'LoadBalancers[0].LoadBalancerArn' --output text)

# Save NLB ARN for later during deprovision
echo ${nlb_arn} >${SHARED_DIR}/nlb_arn.txt

echo "Waiting for Network Load Balancer to become available..."

aws elbv2 wait load-balancer-available --load-balancer-arns "${nlb_arn}"

echo "Network Load Balancer created."

# Create the Target Groups and save to tg_arn.txt for later during deprovision
echo "Creating Target Groups for 80/tcp, 443/tcp, and 6443/tcp..."

http_tg_arn=$(aws elbv2 create-target-group --name ${cluster_name}-http --protocol TCP --port 80 --vpc-id ${vpc_id} --target-type ip --query 'TargetGroups[0].TargetGroupArn' --output text)
echo ${http_tg_arn} >${SHARED_DIR}/tg_arn.txt

https_tg_arn=$(aws elbv2 create-target-group --name ${cluster_name}-https --protocol TCP --port 443 --vpc-id ${vpc_id} --target-type ip --query 'TargetGroups[0].TargetGroupArn' --output text)
echo ${https_tg_arn} >>${SHARED_DIR}/tg_arn.txt

api_tg_arn=$(aws elbv2 create-target-group --name ${cluster_name}-api --protocol TCP --port 6443 --vpc-id ${vpc_id} --target-type ip --query 'TargetGroups[0].TargetGroupArn' --output text)
echo ${api_tg_arn} >>${SHARED_DIR}/tg_arn.txt

echo "Target Groups created."

# Register the API and Ingress VIPs with Target Groups
echo "Registering VIPs with Target Groups..."

aws elbv2 register-targets \
  --target-group-arn ${http_tg_arn} \
  --targets Id="${vips[1]}",Port=80,AvailabilityZone=all

aws elbv2 register-targets \
  --target-group-arn ${https_tg_arn} \
  --targets Id="${vips[1]}",Port=443,AvailabilityZone=all

aws elbv2 register-targets \
  --target-group-arn ${api_tg_arn} \
  --targets Id="${vips[0]}",Port=6443,AvailabilityZone=all

echo "VIPs registered."

# Register the VIPs with Target Groups and NLB
echo "Creating Listeners..."

aws elbv2 create-listener \
  --load-balancer-arn ${nlb_arn} \
  --protocol TCP \
  --port 80 \
  --default-actions Type=forward,TargetGroupArn=${http_tg_arn}

aws elbv2 create-listener \
  --load-balancer-arn ${nlb_arn} \
  --protocol TCP \
  --port 443 \
  --default-actions Type=forward,TargetGroupArn=${https_tg_arn}

aws elbv2 create-listener \
  --load-balancer-arn ${nlb_arn} \
  --protocol TCP \
  --port 6443 \
  --default-actions Type=forward,TargetGroupArn=${api_tg_arn}

echo "Listeners created."
