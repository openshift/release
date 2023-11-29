#!/bin/bash

set -o nounset
set -o errexit
set -o pipefail

cluster_name=${NAMESPACE}-${UNIQUE_HASH}
base_domain="${cluster_name}.vmc-ci.devcluster.openshift.com"

export AWS_DEFAULT_REGION=us-west-2 # TODO: Derive this?
export AWS_SHARED_CREDENTIALS_FILE=/var/run/vault/vsphere/.awscred
export AWS_MAX_ATTEMPTS=50
export AWS_RETRY_MODE=adaptive
export HOME=/tmp

SUBNETS_CONFIG=/var/run/vault/vsphere-config/subnets.json

declare vlanid
declare primaryrouterhostname
source "${SHARED_DIR}/vsphere_context.sh"

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

if ! jq -e --arg PRH "$primaryrouterhostname" --arg VLANID "$vlanid" '.[$PRH] | has($VLANID)' "${SUBNETS_CONFIG}"; then
  echo "VLAN ID: ${vlanid} does not exist on ${primaryrouterhostname} in subnets.json file. This exists in vault - selfservice/vsphere-vmc/config"
  exit 1
fi
load_balancer_ip=$(jq -r --arg VLANID "$vlanid" --arg PRH "$primaryrouterhostname" '.[$PRH][$VLANID].ipAddresses[2]' "${SUBNETS_CONFIG}")

# Create Network Load Balancer in the subnet that is routable into VMC network
vpc_id=$(aws ec2 describe-vpcs --filters Name=tag:"aws:cloudformation:stack-name",Values=vsphere-vpc --query 'Vpcs[0].VpcId' --output text)
vmc_subnet="subnet-011c2a9515cdc7ef7" # TODO: Derive this?

echo "$(date -u --rfc-3339=seconds) - creating Network Load Balancer..."

nlb_arn=$(aws elbv2 create-load-balancer --name ${cluster_name} --subnets ${vmc_subnet} --type network --query 'LoadBalancers[0].LoadBalancerArn' --output text)

# Save NLB ARN for later during deprovision
echo ${nlb_arn} >${SHARED_DIR}/nlb_arn.txt

echo "$(date -u --rfc-3339=seconds) - waiting for Network Load Balancer to become available..."

aws elbv2 wait load-balancer-available --load-balancer-arns "${nlb_arn}"

echo "$(date -u --rfc-3339=seconds) - network Load Balancer created."

# Create the Target Groups and save to tg_arn.txt for later during deprovision
echo "$(date -u --rfc-3339=seconds) - creating Target Groups for 80/tcp, 443/tcp, and 6443/tcp..."

http_tg_arn=$(aws elbv2 create-target-group --name ${cluster_name}-http --protocol TCP --port 80 --vpc-id ${vpc_id} --target-type ip --query 'TargetGroups[0].TargetGroupArn' --output text)
echo ${http_tg_arn} >${SHARED_DIR}/tg_arn.txt

https_tg_arn=$(aws elbv2 create-target-group --name ${cluster_name}-https --protocol TCP --port 443 --vpc-id ${vpc_id} --target-type ip --query 'TargetGroups[0].TargetGroupArn' --output text)
echo ${https_tg_arn} >>${SHARED_DIR}/tg_arn.txt

api_tg_arn=$(aws elbv2 create-target-group --name ${cluster_name}-api --protocol TCP --port 6443 --vpc-id ${vpc_id} --target-type ip --query 'TargetGroups[0].TargetGroupArn' --output text)
echo ${api_tg_arn} >>${SHARED_DIR}/tg_arn.txt

echo "$(date -u --rfc-3339=seconds) - target Groups created."

# Register the API and Ingress VIPs with Target Groups
echo "$(date -u --rfc-3339=seconds) - registering load balancer with target groups..."

aws elbv2 register-targets \
  --target-group-arn ${http_tg_arn} \
  --targets Id="${load_balancer_ip}",Port=80,AvailabilityZone=all

aws elbv2 register-targets \
  --target-group-arn ${https_tg_arn} \
  --targets Id="${load_balancer_ip}",Port=443,AvailabilityZone=all

aws elbv2 register-targets \
  --target-group-arn ${api_tg_arn} \
  --targets Id="${load_balancer_ip}",Port=6443,AvailabilityZone=all

echo "$(date -u --rfc-3339=seconds) - load balancer registered"

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

echo "$(date -u --rfc-3339=seconds) - listeners created"

hosted_zone_id="$(aws route53 list-hosted-zones-by-name \
  --dns-name "${base_domain}" \
  --query "HostedZones[? Config.PrivateZone != \`true\` && Name == \`${base_domain}.\`].Id" \
  --output text)"
echo "${hosted_zone_id}" >"${SHARED_DIR}/hosted-zone.txt"

# Configure DNS target as previously configured NLB
nlb_arn=$(<"${SHARED_DIR}"/nlb_arn.txt)
nlb_dnsname="$(aws elbv2 describe-load-balancers \
  --load-balancer-arns ${nlb_arn} \
  --query 'LoadBalancers[0].DNSName' \
  --output text)"
nlb_hosted_zone_id="$(aws elbv2 describe-load-balancers \
  --load-balancer-arns ${nlb_arn} \
  --query 'LoadBalancers[0].CanonicalHostedZoneId' \
  --output text)"

# Both API and *.apps pipe through same NLB
api_dns_target='"AliasTarget": {
    "HostedZoneId": "'${nlb_hosted_zone_id}'",
    "DNSName": "'${nlb_dnsname}'",
    "EvaluateTargetHealth": false
    }'
apps_dns_target=$api_dns_target

# api-int record is needed just for Windows nodes
# TODO: Remove the api-int entry in future
echo "$(date -u --rfc-3339=seconds) - creating DNS records"
cat >"${SHARED_DIR}"/dns-create.json <<EOF
{
"Comment": "Create public OpenShift DNS records for VSphere UPI clusterbot install",
"Changes": [{
    "Action": "UPSERT",
    "ResourceRecordSet": {
      "Name": "api.$base_domain.",
      "Type": "A",
      $api_dns_target
      }
    },{
    "Action": "UPSERT",
    "ResourceRecordSet": {
      "Name": "api-int.$base_domain.",
      "Type": "A",
      "TTL": 60,
      "ResourceRecords": [{"Value": "${load_balancer_ip}"}]
      }
    },{
    "Action": "UPSERT",
    "ResourceRecordSet": {
      "Name": "*.apps.$base_domain.",
      "Type": "A",
      $apps_dns_target
      }
}]}
EOF

id=$(aws route53 change-resource-record-sets --hosted-zone-id "$hosted_zone_id" --change-batch file:///"${SHARED_DIR}"/dns-create.json --query '"ChangeInfo"."Id"' --output text)

echo "$(date -u --rfc-3339=seconds) - waiting for DNS records to sync"

aws route53 wait resource-record-sets-changed --id "$id"

echo "$(date -u --rfc-3339=seconds) - DNS records created"
