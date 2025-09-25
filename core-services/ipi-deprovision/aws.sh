#!/bin/bash
set -o errexit
set -o nounset
set -o pipefail

PROFILE="${1:-default}"
CUTOFF="$(date -d '72 hours ago' --iso-8601=seconds)"
MAX_RETRIES=5

log() { echo "[$(date -u +%Y-%m-%dT%H:%M:%SZ)] $*"; }

retry() {
  local attempt=0
  until "$@"; do
    attempt=$(( attempt + 1 ))
    if (( attempt >= MAX_RETRIES )); then
      log "ERROR: command failed after $MAX_RETRIES attempts: $*"
      return 1
    fi
    sleep_time=$(( attempt * 5 ))
    log "WARN: retrying ($attempt/$MAX_RETRIES) after $sleep_time seconds: $*"
    sleep "$sleep_time"
  done
}

# IAM User Cleanup
cleanup_iam_users() {
  aws --profile "$PROFILE" iam list-users \
    --query "Users[?starts_with(UserName, 'ci-op-') && CreateDate < \`$CUTOFF\`].UserName" \
    --output text | tr '\t' '\n' | while read -r user; do
      [[ -z "$user" ]] && continue
      log "Processing IAM user: $user"

      # detach managed policy
      for policy in $(aws --profile "$PROFILE" iam list-attached-user-policies \
        --user-name "$user" --query 'AttachedPolicies[].PolicyArn' --output text 2>/dev/null); do
          retry aws --profile "$PROFILE" iam detach-user-policy --user-name "$user" --policy-arn "$policy" || true
      done

      # delete inline policy
      for policy in $(aws --profile "$PROFILE" iam list-user-policies \
        --user-name "$user" --query 'PolicyNames[]' --output text 2>/dev/null); do
          retry aws --profile "$PROFILE" iam delete-user-policy --user-name "$user" --policy-name "$policy" || true
      done

      # delete access key
      for key in $(aws --profile "$PROFILE" iam list-access-keys \
        --user-name "$user" --query 'AccessKeyMetadata[].AccessKeyId' --output text 2>/dev/null); do
          retry aws --profile "$PROFILE" iam delete-access-key --user-name "$user" --access-key-id "$key" || true
      done

      # remove from group
      for group in $(aws --profile "$PROFILE" iam get-groups-for-user \
        --user-name "$user" --query 'Groups[].GroupName' --output text 2>/dev/null); do
          retry aws --profile "$PROFILE" iam remove-user-from-group --user-name "$user" --group-name "$group" || true
      done

      # delete user
      if retry aws --profile "$PROFILE" iam delete-user --user-name "$user"; then
        log "✓ Deleted IAM user: $user"
      else
        log "✗ Failed to delete IAM user: $user"
      fi
  done
}

# Route53 cleanup
cleanup_route53() {
  aws --profile "$PROFILE" route53 list-hosted-zones --query "HostedZones[].Id" --output text | tr '\t' '\n' | while read -r zone_id; do
    [[ -z "$zone_id" ]] && continue
    zone_name=$(aws --profile "$PROFILE" route53 get-hosted-zone --id "$zone_id" --query 'HostedZone.Name' --output text)
    if [[ "$zone_name" == ci-op-* ]]; then
      log "Cleaning Route53 zone: $zone_name ($zone_id)"
      # delete all records except SOA/NS
      # This is to avoid the "Resource not found" error when deleting the zone
      records=$(aws --profile "$PROFILE" route53 list-resource-record-sets --hosted-zone-id "$zone_id" \
        --query "ResourceRecordSets[?Type != 'SOA' && Type != 'NS']" --output json)
      if [[ "$records" != "[]" ]]; then
        change_batch=$(jq -c '{Changes: map({Action:"DELETE", ResourceRecordSet:.})}' <<<"$records")
        retry aws --profile "$PROFILE" route53 change-resource-record-sets \
          --hosted-zone-id "$zone_id" --change-batch "$change_batch" || true
      fi
      retry aws --profile "$PROFILE" route53 delete-hosted-zone --id "$zone_id" || true
    fi
  done
}

# Hypershift cleanup
cleanup_hypershift() {
  log "Running Hypershift pruner..."
  retry pruner hypershift --cutoff="$CUTOFF" --profile "$PROFILE" || true
}

# VPC cleanup
cleanup_vpcs() {
  aws --profile "$PROFILE" ec2 describe-vpcs \
    --query "Vpcs[?Tags[?Key=='kubernetes.io/cluster/ci-op-*'] && CreateTime<\`$CUTOFF\`].VpcId" \
    --output text | tr '\t' '\n' | while read -r vpc; do
      [[ -z "$vpc" ]] && continue
      log "Cleaning VPC: $vpc"

      # delete dependencies
      for gw in $(aws --profile "$PROFILE" ec2 describe-internet-gateways \
        --filters "Name=attachment.vpc-id,Values=$vpc" --query "InternetGateways[].InternetGatewayId" --output text); do
          retry aws --profile "$PROFILE" ec2 detach-internet-gateway --internet-gateway-id "$gw" --vpc-id "$vpc" || true
          retry aws --profile "$PROFILE" ec2 delete-internet-gateway --internet-gateway-id "$gw" || true
      done

      for sg in $(aws --profile "$PROFILE" ec2 describe-security-groups \
        --filters Name=vpc-id,Values=$vpc --query "SecurityGroups[?GroupName!='default'].GroupId" --output text); do
          retry aws --profile "$PROFILE" ec2 delete-security-group --group-id "$sg" || true
      done

      for subnet in $(aws --profile "$PROFILE" ec2 describe-subnets \
        --filters Name=vpc-id,Values=$vpc --query "Subnets[].SubnetId" --output text); do
          retry aws --profile "$PROFILE" ec2 delete-subnet --subnet-id "$subnet" || true
      done

      for ngw in $(aws --profile "$PROFILE" ec2 describe-nat-gateways \
        --filter Name=vpc-id,Values=$vpc --query "NatGateways[].NatGatewayId" --output text); do
          retry aws --profile "$PROFILE" ec2 delete-nat-gateway --nat-gateway-id "$ngw" || true
      done

      for eni in $(aws --profile "$PROFILE" ec2 describe-network-interfaces \
        --filters Name=vpc-id,Values=$vpc --query "NetworkInterfaces[].NetworkInterfaceId" --output text); do
          retry aws --profile "$PROFILE" ec2 delete-network-interface --network-interface-id "$eni" || true
      done

      retry aws --profile "$PROFILE" ec2 delete-vpc --vpc-id "$vpc" || true
      log "✓ VPC cleaned: $vpc"
  done
}

# Run all cleanups in parallel
main() {
  log "Starting deprovision"

  cleanup_iam_users &
  cleanup_route53 &
  cleanup_hypershift &
  cleanup_vpcs &

  wait
  log "Deprovision finished successfully."
}

main "$@"
