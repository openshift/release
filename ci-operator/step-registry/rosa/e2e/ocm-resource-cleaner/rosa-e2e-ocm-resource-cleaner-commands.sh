#!/bin/bash
set -o nounset
set -o pipefail

export AWS_SHARED_CREDENTIALS_FILE="${OCM_CLEANER_CREDENTIALS_FILE:-/usr/local/cs-qe-credentials/aws-cred-ocp5}"

REGIONS="${OCM_CLEANER_REGIONS:-us-west-2 us-east-1 us-east-2 eu-west-1 ap-southeast-1}"
HOURS_OLD="${OCM_CLEANER_HOURS_OLD:-12}"

# VPC profile names created by OCM backend FVT tests (kept in sync with vpc_cleanup.py)
PROFILE_NAMES=(
  "sdq-rosa-hcp-ad" "sdq-rosa-sts-ad" "sdq-rosa-sts-shared-vpc" "sdq-rosa-sts-pl"
  "sdq-rosa-hcp-pl" "sdq-rosa-ad" "sdq-rosa-hcp-z-upg" "sdq-rosa-hcp-y-upg"
  "sdq-rosa-sts-upgrade" "sdq-rosa-hcp-ibm" "sdq-osd-ccs-gcp-marketplace"
  "sdq-rosa-hcp-adobe" "sdq-rosa-hcp-arm" "sdq-osd-gcp-wif-sv" "sdq-osd-ccs-gcp-ad"
  "sdq-osd-rh-aws" "sdq-osd-ccs-aws-ad" "sdq-osd-rh-gcp" "sdq-osd-gcp-psc-wif-sv"
  "sdq-rosa-hcp-zero-egress" "sdq-rosa-hcp-shared-vpc" "sdq-rosa-sts-upgrade-sdn"
  "sdq-osd-gcp-non-cross-project-wif" "sdq-rosa-hcp-bkp" "sdq-rosa-hcp-zero-egress-upgrade"
)

cutoff_epoch=$(date -u -d "${HOURS_OLD} hours ago" '+%s')
echo "Cleaning resources older than ${HOURS_OLD}h (cutoff epoch: ${cutoff_epoch})"
echo "Regions: ${REGIONS}"
echo ""

overall_exit=0

# Deletes a resource if its creation time (ISO-8601) is older than the cutoff epoch.
# Uses epoch comparison to avoid lexical ambiguity between Z and +00:00 suffixes.
delete_if_old() {
  local resource_type="$1"
  local resource_id="$2"
  local create_time="$3"
  local delete_cmd="$4"

  local create_epoch
  create_epoch=$(date -u -d "${create_time}" '+%s' 2>/dev/null) || {
    echo "    WARNING: could not parse timestamp '${create_time}' for ${resource_type} ${resource_id}, skipping" >&2
    return
  }

  if [[ "${create_epoch}" -lt "${cutoff_epoch}" ]]; then
    echo "    Deleting stale ${resource_type} ${resource_id} (created ${create_time})"
    if ! eval "${delete_cmd}" 2>/dev/null; then
      echo "    WARNING: failed to delete ${resource_type} ${resource_id}" >&2
      overall_exit=1
    fi
  else
    echo "    Skipping recent ${resource_type} ${resource_id} (${create_time})"
  fi
}

# Runs an AWS discovery command and writes output to a variable.
# Sets overall_exit=1 on failure so credential/API errors are not silently swallowed.
aws_query() {
  local desc="$1"
  shift
  local output
  if ! output=$(aws "$@" 2>&1); then
    echo "  WARNING: failed to query ${desc}: ${output}" >&2
    overall_exit=1
    echo ""
    return 1
  fi
  echo "${output}"
}

for region in ${REGIONS}; do
  echo "=== Region: ${region} ==="

  for profile_name in "${PROFILE_NAMES[@]}"; do
    vpc_ids=$(aws_query "VPCs (${profile_name})" ec2 describe-vpcs --region "${region}" \
      --filters "Name=tag:Name,Values=${profile_name}" \
      --query 'Vpcs[].VpcId' --output text) || continue

    [[ -z "${vpc_ids}" || "${vpc_ids}" == "None" ]] && continue

    for vpc_id in ${vpc_ids}; do
      echo "  VPC ${vpc_id} (${profile_name})"

      # Delete ALB/NLB load balancers older than threshold
      alb_output=$(aws_query "ALBs in ${vpc_id}" elbv2 describe-load-balancers --region "${region}" \
        --query "LoadBalancers[?VpcId=='${vpc_id}'].[LoadBalancerArn,CreatedTime]" \
        --output text) || true
      while IFS=$'\t' read -r arn create_time; do
        [[ -z "${arn}" || "${arn}" == "None" ]] && continue
        delete_if_old "ALB/NLB" "${arn}" "${create_time}" \
          "aws elbv2 delete-load-balancer --region ${region} --load-balancer-arn ${arn}"
      done <<< "${alb_output}"

      # Delete classic ELBs older than threshold
      elb_output=$(aws_query "classic ELBs in ${vpc_id}" elb describe-load-balancers --region "${region}" \
        --query "LoadBalancerDescriptions[?VPCId=='${vpc_id}'].[LoadBalancerName,CreatedTime]" \
        --output text) || true
      while IFS=$'\t' read -r lb_name create_time; do
        [[ -z "${lb_name}" || "${lb_name}" == "None" ]] && continue
        delete_if_old "classic-ELB" "${lb_name}" "${create_time}" \
          "aws elb delete-load-balancer --region ${region} --load-balancer-name ${lb_name}"
      done <<< "${elb_output}"

      # Delete NAT gateways older than threshold
      nat_output=$(aws_query "NAT gateways in ${vpc_id}" ec2 describe-nat-gateways --region "${region}" \
        --filter "Name=vpc-id,Values=${vpc_id}" "Name=state,Values=available,pending,failed" \
        --query 'NatGateways[].[NatGatewayId,CreateTime]' --output text) || continue
      while IFS=$'\t' read -r nat_id create_time; do
        [[ -z "${nat_id}" || "${nat_id}" == "None" ]] && continue
        delete_if_old "NAT-gateway" "${nat_id}" "${create_time}" \
          "aws ec2 delete-nat-gateway --region ${region} --nat-gateway-id ${nat_id}"
      done <<< "${nat_output}"
    done
  done

  # Release unassociated EIPs (dedicated OCP5 test account — all unassociated EIPs are stale)
  echo "  Releasing unassociated EIPs in ${region}..."
  eip_output=$(aws_query "EIPs in ${region}" ec2 describe-addresses --region "${region}" \
    --query 'Addresses[?AssociationId==null].[AllocationId,PublicIp]' --output text) || true
  while IFS=$'\t' read -r alloc_id public_ip; do
    [[ -z "${alloc_id}" || "${alloc_id}" == "None" ]] && continue
    echo "  Releasing EIP ${alloc_id} (${public_ip})"
    if ! aws ec2 release-address --region "${region}" --allocation-id "${alloc_id}" 2>/dev/null; then
      echo "  WARNING: failed to release EIP ${alloc_id}" >&2
      overall_exit=1
    fi
  done <<< "${eip_output}"

  echo "=== Done: ${region} ==="
  echo ""
done

# Clean up stale IAM operator roles (op-gate-stg-* prefix, global resource).
# These are created per cluster by the OCP5 operator credential flow and are
# not removed when the cluster is deleted, causing the account to hit the
# 1000-role quota limit over time.
#
# Safety: all OCP5 FVT jobs have a maximum Prow timeout of 5h. Using the
# default HOURS_OLD=12 means any role older than 12h is guaranteed to belong
# to a cluster that has already finished (and been deleted by OCM). No OCM
# API check is needed — the age threshold is the cluster-liveness proxy.
echo "=== IAM operator role cleanup (global) ==="
echo "  Listing op-gate-stg-* roles older than ${HOURS_OLD}h..."

iam_roles_output=""
if ! iam_roles_output=$(aws iam list-roles \
  --query 'Roles[?starts_with(RoleName, `op-gate-stg-`)].[RoleName,CreateDate]' \
  --output text 2>&1); then
  echo "  WARNING: failed to query op-gate-stg-* IAM roles: ${iam_roles_output}" >&2
  overall_exit=1
  iam_roles_output=""
fi

iam_deleted=0
iam_skipped=0
while IFS=$'\t' read -r role_name create_time; do
  [[ -z "${role_name}" || "${role_name}" == "None" ]] && continue

  create_epoch=$(date -u -d "${create_time}" '+%s' 2>/dev/null) || {
    echo "  WARNING: could not parse timestamp '${create_time}' for role ${role_name}, skipping" >&2
    continue
  }

  if [[ "${create_epoch}" -ge "${cutoff_epoch}" ]]; then
    iam_skipped=$((iam_skipped + 1))
    continue
  fi

  echo "  Deleting stale IAM role ${role_name} (created ${create_time})"

  # Detach all managed policies first
  managed=$(aws iam list-attached-role-policies --role-name "${role_name}" \
    --query 'AttachedPolicies[*].PolicyArn' --output text 2>/dev/null) || managed=""
  for arn in ${managed}; do
    aws iam detach-role-policy --role-name "${role_name}" --policy-arn "${arn}" 2>/dev/null || true
  done

  # Delete all inline policies
  inline=$(aws iam list-role-policies --role-name "${role_name}" \
    --query 'PolicyNames' --output text 2>/dev/null) || inline=""
  for policy in ${inline}; do
    aws iam delete-role-policy --role-name "${role_name}" --policy-name "${policy}" 2>/dev/null || true
  done

  if aws iam delete-role --role-name "${role_name}" 2>/dev/null; then
    iam_deleted=$((iam_deleted + 1))
  else
    echo "  WARNING: failed to delete IAM role ${role_name}" >&2
    overall_exit=1
  fi
done <<< "${iam_roles_output}"

echo "  IAM role cleanup done: deleted=${iam_deleted}, skipped_recent=${iam_skipped}"
echo "=== Done: IAM operator roles ==="
echo ""

exit ${overall_exit}
