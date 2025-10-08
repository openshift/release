#!/bin/bash

set -o nounset
set -o errexit
set -o pipefail

trap 'CHILDREN=$(jobs -p); if test -n "${CHILDREN}"; then kill ${CHILDREN} && wait; fi' TERM

export AWS_SHARED_CREDENTIALS_FILE="${CLUSTER_PROFILE_DIR}/.awscred"
REGION="${LEASED_RESOURCE}"
METADATA_FILE="${SHARED_DIR}/metadata.json"

echo "Using AWS region: $REGION"

# Get tag filters and cluster name from metadata.json in order to query for cluster resources
TAG_FILTERS=$(jq -r '.aws.identifier[] | to_entries[] | "--tag-filters Key=\"\(.key)\",Values=\"\(.value)\""' "$METADATA_FILE" | tr '\n' ' ')

if [[ -z "$TAG_FILTERS" ]]; then
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
run_command "aws resourcegroupstaggingapi get-resources --region $REGION $TAG_FILTERS" "TAGGED_RESOURCES"

# To avoid iterating through all IAM users, we will rely on the convention that all IAM users begin with the cluster name.
# Don't bother with other IAM resources (e.g. access keys, policies), as they depend on the user to exist. If the user is gone, so are they.
run_command "aws iam list-users --query 'Users[?starts_with(UserName, \`$CLUSTER_NAME\`)].Arn'" "IAM_USERS"

# Combine tagged resources and IAM users into a single array of ARNs
LEAKED_ARNS=$(jq -n --argjson tagged "$TAGGED_RESOURCES" --argjson iam "$IAM_USERS" '$tagged.ResourceTagMappingList | map(.ResourceARN) + $iam')

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
