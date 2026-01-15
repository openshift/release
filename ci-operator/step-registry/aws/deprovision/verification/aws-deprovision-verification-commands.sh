#!/bin/bash

set -o nounset
set -o errexit
set -o pipefail

trap 'CHILDREN=$(jobs -p); if test -n "${CHILDREN}"; then kill ${CHILDREN} && wait; fi' TERM

export AWS_SHARED_CREDENTIALS_FILE="${CLUSTER_PROFILE_DIR}/.awscred"
REGION="${LEASED_RESOURCE}"
METADATA_FILE="${SHARED_DIR}/metadata.json"

function run_command() {
    local cmd="$1"
    local var_name="$2"
    echo "Running Command: ${cmd}"
    eval "${var_name}=\$(eval \"\${cmd}\")"
}

function verify_arn_exists() {
    local arn="$1"
    # Parse ARN: arn:partition:service:region:account-id:resource
    # Returns 0 if resource exists, 1 if deleted or not found

    local service
    service=$(echo "$arn" | cut -d: -f3)
    local resource_part
    resource_part=$(echo "$arn" | cut -d: -f6-)
    local arn_region
    arn_region=$(echo "$arn" | cut -d: -f4)

    # Use the ARN's region if specified, otherwise use the cluster region
    local check_region="${arn_region:-$REGION}"

    case "$service" in
        ec2)
            # Parse resource type and ID from resource part
            local resource_type
            resource_type=$(echo "$resource_part" | cut -d/ -f1 | cut -d: -f1)
            local resource_id
            resource_id=$(echo "$resource_part" | cut -d/ -f2-)

            case "$resource_type" in
                instance)
                    local instances
                    instances=$(aws ec2 describe-instances --region "$check_region" --instance-ids "$resource_id" --filters "Name=instance-state-name,Values=running" 2>/dev/null)
                    local exit_code=$?
                    if [[ $exit_code -ne 0 ]]; then
                        return 1
                    fi
                    # Check if Reservations array is empty (happens when instance is deleted)
                    local reservation_count
                    reservation_count=$(echo "$instances" | jq -r '.Reservations | length')
                    if [[ "$reservation_count" -eq 0 ]]; then
                        return 1
                    fi
                    return 0
                    ;;
                volume)
                    aws ec2 describe-volumes --region "$check_region" --volume-ids "$resource_id" --filters "Name=status,Values=available,in-use" &>/dev/null
                    return $?
                    ;;
                security-group)
                    aws ec2 describe-security-groups --region "$check_region" --group-ids "$resource_id" &>/dev/null
                    return $?
                    ;;
                vpc)
                    aws ec2 describe-vpcs --region "$check_region" --vpc-ids "$resource_id" &>/dev/null
                    return $?
                    ;;
                subnet)
                    aws ec2 describe-subnets --region "$check_region" --subnet-ids "$resource_id" &>/dev/null
                    return $?
                    ;;
                network-interface)
                    aws ec2 describe-network-interfaces --region "$check_region" --network-interface-ids "$resource_id" &>/dev/null
                    return $?
                    ;;
                egress-only-internet-gateway)
                    aws ec2 describe-egress-only-internet-gateways --region "$check_region" --egress-only-internet-gateway-ids "$resource_id" &>/dev/null
                    return $?
                    ;;
                internet-gateway)
                    aws ec2 describe-internet-gateways --region "$check_region" --internet-gateway-ids "$resource_id" &>/dev/null
                    return $?
                    ;;
                route-table)
                    aws ec2 describe-route-tables --region "$check_region" --route-table-ids "$resource_id" &>/dev/null
                    return $?
                    ;;
                natgateway)
                    local natgws
                    natgws=$(aws ec2 describe-nat-gateways --region "$check_region" --nat-gateway-ids "$resource_id"  --filter Name=state,Values=available 2>/dev/null)
                    local exit_code=$?
                    if [[ $exit_code -ne 0 ]]; then
                        return 1
                    fi
                    # Check if NatGateways array is empty (happens when NAT gateway is deleted)
                    local nat_gateway_count
                    nat_gateway_count=$(echo "$natgws" | jq -r '.NatGateways | length')
                    if [[ "$nat_gateway_count" -eq 0 ]]; then
                        return 1
                    fi
                    return 0
                    ;;
                elastic-ip)
                    aws ec2 describe-addresses --region "$check_region" --allocation-ids "$resource_id" &>/dev/null
                    return $?
                    ;;
                vpc-endpoint)
                    aws ec2 describe-vpc-endpoints --region "$check_region" --vpc-endpoint-ids "$resource_id" &>/dev/null
                    return $?
                    ;;
                *)
                    # For unknown EC2 resource types, assume it exists to be safe
                    echo "  Warning: Unknown EC2 resource type '$resource_type' for ARN: $arn" >&2
                    return 0
                    ;;
            esac
            ;;
        s3)
            # S3 buckets are global but API calls can be made from any region
            local bucket_name
            bucket_name=$(echo "$resource_part" | cut -d/ -f1 | cut -d: -f1)
            aws s3api head-bucket --bucket "$bucket_name" &>/dev/null
            return $?
            ;;
        iam)
            # IAM is global
            local resource_type
            resource_type=$(echo "$resource_part" | cut -d/ -f1 | cut -d: -f1)
            local resource_name
            resource_name=$(echo "$resource_part" | cut -d/ -f2-)

            case "$resource_type" in
                user)
                    aws iam get-user --user-name "$resource_name" &>/dev/null
                    return $?
                    ;;
                role)
                    aws iam get-role --role-name "$resource_name" &>/dev/null
                    return $?
                    ;;
                policy)
                    aws iam get-policy --policy-arn "$arn" &>/dev/null
                    return $?
                    ;;
                instance-profile)
                    aws iam get-instance-profile --instance-profile-name "$resource_name" &>/dev/null
                    return $?
                    ;;
                *)
                    echo "  Warning: Unknown IAM resource type '$resource_type' for ARN: $arn" >&2
                    return 0
                    ;;
            esac
            ;;
        elasticloadbalancing)
            if [[ "$resource_part" == loadbalancer/app/* ]] || [[ "$resource_part" == loadbalancer/net/* ]]; then
                # ALB/NLB (ELBv2)
                aws elbv2 describe-load-balancers --region "$check_region" --load-balancer-arns "$arn" &>/dev/null
                return $?
            elif [[ "$resource_part" == listener/app/* ]] || [[ "$resource_part" == listener/net/* ]]; then
                # Listeners (ELBv2)
                aws elbv2 describe-listeners --region "$check_region" --listener-arns "$arn" &>/dev/null
                return $?
            elif [[ "$resource_part" == targetgroup/* ]]; then
                # Target groups (ELBv2)
                aws elbv2 describe-target-groups --region "$check_region" --target-group-arns "$arn" &>/dev/null
                return $?
            else
                # Classic ELB
                local lb_name
                lb_name=$(echo "$resource_part" | cut -d/ -f2)
                aws elb describe-load-balancers --region "$check_region" --load-balancer-names "$lb_name" &>/dev/null
                return $?
            fi
            ;;
        route53)
            # Route53 is global
            local hosted_zone_id
            hosted_zone_id=$(echo "$resource_part" | cut -d/ -f2)
            aws route53 get-hosted-zone --id "$hosted_zone_id" &>/dev/null
            return $?
            ;;
        elasticfilesystem)
            # EFS
            local fs_id
            fs_id=$(echo "$resource_part" | cut -d/ -f2)
            aws efs describe-file-systems --region "$check_region" --file-system-id "$fs_id" &>/dev/null
            return $?
            ;;
        *)
            # For unknown services, assume resource exists to be safe (avoid false negatives)
            echo "  Warning: Unknown service '$service' for ARN: $arn" >&2
            return 0
            ;;
    esac
}

echo "Using AWS region: $REGION"

# Get tag filters and cluster name from metadata.json in order to query for cluster resources
# Extract each tag filter into an array
readarray -t TAG_FILTERS_ARRAY < <(jq -r '.aws.identifier[] | to_entries[] | "--tag-filters Key=\"\(.key)\",Values=\"\(.value)\""' "$METADATA_FILE")

if [[ ${#TAG_FILTERS_ARRAY[@]} -eq 0 ]]; then
    echo "Error: No tag filters found in metadata.json" >&2
    exit 1
fi

CLUSTER_NAME=$(jq -r '.clusterName' "$METADATA_FILE")

if [[ -z "$CLUSTER_NAME" ]]; then
    echo "Error: No cluster name found in metadata.json" >&2
    exit 1
fi

# We will also need the cluster's basedomain, which is not in the metadata.json.
# Installer destroy discovers it off the tagged private zoned, but in CI we already have it available.
if [[ ! -r "${CLUSTER_PROFILE_DIR}/baseDomain" ]]; then
  echo "Using default value: ${BASE_DOMAIN}"
  AWS_BASE_DOMAIN="${BASE_DOMAIN}"
else
  AWS_BASE_DOMAIN=$(< "${CLUSTER_PROFILE_DIR}/baseDomain")
fi

# Find all tagged resources (except IAM users which requires iterating through each resource)
# Make a separate call for each TAG_FILTER and combine results
echo "Making separate AWS API calls for each tag filter..."
TAGGED_RESOURCES_LIST=()

for TAG_FILTER in "${TAG_FILTERS_ARRAY[@]}"; do
    SINGLE_RESULT=""
    run_command "aws resourcegroupstaggingapi get-resources --region $REGION $TAG_FILTER" "SINGLE_RESULT"
    TAGGED_RESOURCES_LIST+=("$SINGLE_RESULT")
done

# Combine all results into a single TAGGED_RESOURCES variable
# Merge ResourceTagMappingList arrays from all responses and remove duplicates by ResourceARN
if [[ ${#TAGGED_RESOURCES_LIST[@]} -gt 0 ]]; then
    TAGGED_RESOURCES=$(jq -n --argjson results "$(printf '%s\n' "${TAGGED_RESOURCES_LIST[@]}" | jq -s '.')" \
        '{ResourceTagMappingList: ($results | map(.ResourceTagMappingList) | flatten | unique_by(.ResourceARN))}')
else
    TAGGED_RESOURCES='{"ResourceTagMappingList":[]}'
fi

# To avoid iterating through all IAM users, we will rely on the convention that all IAM users begin with the cluster name.
# Don't bother with other IAM resources (e.g. access keys, policies), as they depend on the user to exist. If the user is gone, so are they.
run_command "aws iam list-users --query 'Users[?starts_with(UserName, \`$CLUSTER_NAME\`)].Arn'" "IAM_USERS"

# Combine tagged resources and IAM users into a single array of ARNs
LEAKED_ARNS=$(jq -n --argjson tagged "$TAGGED_RESOURCES" --argjson iam "$IAM_USERS" '$tagged.ResourceTagMappingList | map(.ResourceARN) + $iam')

echo "Confirming that the ARNs we discovered have not actually been deleted..."
VERIFIED_ARNS=()
ARN_COUNT=$(echo "$LEAKED_ARNS" | jq -r 'length')

if [[ "$ARN_COUNT" -gt 0 ]]; then
    while IFS= read -r arn; do
        if verify_arn_exists "$arn"; then
            VERIFIED_ARNS+=("$arn")
        else
            echo "  $arn was returned by resourcegroupstaggingapi but has been deleted"
        fi
    done < <(echo "$LEAKED_ARNS" | jq -r '.[]')

    # Convert verified ARNs back to JSON array
    if [[ ${#VERIFIED_ARNS[@]} -gt 0 ]]; then
        LEAKED_ARNS=$(printf '%s\n' "${VERIFIED_ARNS[@]}" | jq -R -s -c 'split("\n") | map(select(length > 0))')
    else
        LEAKED_ARNS='[]'
    fi
else
    echo "No ARNs to verify"
    LEAKED_ARNS='[]'
fi

# DNS records are not tagged, but for this test we can depend on the fact that test clusters always use a unique name (so there will not be false-positive matches)
# Find the public hosted zone using the base domain
run_command "aws route53 list-hosted-zones-by-name --dns-name \"$AWS_BASE_DOMAIN\" --query \"HostedZones[?Name=='${AWS_BASE_DOMAIN}.' && Config.PrivateZone==\\\`false\\\`].Id\" --output text | cut -d'/' -f3" "HOSTED_ZONE_ID"

if [[ -n "$HOSTED_ZONE_ID" ]]; then
  run_command "aws route53 list-resource-record-sets --hosted-zone-id $HOSTED_ZONE_ID --query \"ResourceRecordSets[?contains(Name, \\\`${CLUSTER_NAME}.${AWS_BASE_DOMAIN}\\\`)]\"" "DNS_RECORDS"
fi

# Check if any resources were returned
RESOURCE_COUNT=$(echo "$LEAKED_ARNS" | jq 'length')
DNS_RECORD_COUNT=$(echo "${DNS_RECORDS:-[]}" | jq 'length')

TOTAL_LEAKED=$((RESOURCE_COUNT + DNS_RECORD_COUNT))

if [[ "$TOTAL_LEAKED" -gt 0 ]]; then
    echo "" >&2
    echo "Test Failed: Found $TOTAL_LEAKED leaked resources ($RESOURCE_COUNT ARNs, $DNS_RECORD_COUNT DNS records)" >&2

    if [[ "$RESOURCE_COUNT" -gt 0 ]]; then
        echo "Leaked ARNs:" >&2
        echo "$LEAKED_ARNS" | jq -r '.[]' >&2
    fi

    if [[ "$DNS_RECORD_COUNT" -gt 0 ]]; then
        echo "" >&2
        echo "Leaked DNS Records:" >&2
        echo "$DNS_RECORDS" | jq -r '.[] | .Name' | sed 's/\\052/*/g' >&2
    fi

    exit 1
else
    echo "No leaked resources found"
    exit 0
fi
