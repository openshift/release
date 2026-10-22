#!/bin/bash
set -euo pipefail

export AWS_SHARED_CREDENTIALS_FILE="${CLUSTER_PROFILE_DIR}/.awscred"
export AWS_DEFAULT_REGION="${LEASED_RESOURCE}"
export AWS_PAGER=""
infra_id=$(jq -er '.infraID' "${SHARED_DIR}/metadata.json")
[[ "${infra_id}" =~ ^[a-z0-9-]+$ ]] || { echo "Invalid cluster infrastructure ID" >&2; exit 1; }

# Host-networked PTP proxies listen on 8443, outside the default AWS node
# ingress ranges. Permit only traffic from this cluster's own node groups.
read_groups() {
    aws ec2 describe-security-groups --filters \
        "Name=tag:sigs.k8s.io/cluster-api-provider-aws/cluster/${infra_id},Values=owned" \
        "Name=tag:sigs.k8s.io/cluster-api-provider-aws/role,Values=node,controlplane" \
        --output json
}
read_groups > "${ARTIFACT_DIR}/ptp-tls-security-groups-before.json"
groups="${ARTIFACT_DIR}/ptp-tls-security-groups-before.json"
jq -e --arg infra "${infra_id}" '
    [.SecurityGroups[] | select(.GroupName == ($infra + "-node") or .GroupName == ($infra + "-controlplane"))] as $groups |
    ($groups | length) == 2 and
    ($groups | map(.GroupName) | unique | length) == 2 and
    ($groups | map(.VpcId) | unique | length) == 1 and
    (.SecurityGroups | length) == 2
' "${groups}" > /dev/null || { echo "Expected exactly this cluster's node and control-plane security groups" >&2; exit 1; }

allows_proxy() {
    jq -e --arg target "$1" --arg source "$2" '
        any(.SecurityGroups[] | select(.GroupId == $target) | .IpPermissions[]?;
            (.IpProtocol == "-1" or
             (.IpProtocol == "tcp" and .FromPort <= 8443 and .ToPort >= 8443)) and
            any(.UserIdGroupPairs[]?; .GroupId == $source))
    ' "$3" > /dev/null
}

# Group IDs are supplied by EC2; neither public CIDRs nor other clusters are allowed.
while read -r target; do
    while read -r source; do
        if allows_proxy "${target}" "${source}" "${groups}"; then
            continue
        fi
        echo "Allowing PTP proxy TCP 8443 from ${source} to ${target}"
        if ! aws ec2 authorize-security-group-ingress --group-id "${target}" \
            --protocol tcp --port 8443 --source-group "${source}" \
            > "${ARTIFACT_DIR}/ptp-tls-rule-result.json" 2> "${ARTIFACT_DIR}/ptp-tls-rule-error.log"; then
            # A concurrent reconciler may have added the same rule. Verify below.
            if ! grep -q 'InvalidPermission.Duplicate' "${ARTIFACT_DIR}/ptp-tls-rule-error.log"; then
                cat "${ARTIFACT_DIR}/ptp-tls-rule-error.log" >&2
                exit 1
            fi
        fi
    done < <(jq -r '.SecurityGroups[].GroupId' "${groups}")
done < <(jq -r '.SecurityGroups[].GroupId' "${groups}")

read_groups > "${ARTIFACT_DIR}/ptp-tls-security-groups-after.json"
while read -r target; do
    while read -r source; do
        allows_proxy "${target}" "${source}" "${ARTIFACT_DIR}/ptp-tls-security-groups-after.json" || {
            echo "Missing PTP proxy ingress from ${source} to ${target}" >&2
            exit 1
        }
    done < <(jq -r '.SecurityGroups[].GroupId' "${groups}")
done < <(jq -r '.SecurityGroups[].GroupId' "${groups}")
echo "PTP proxy TCP 8443 is permitted between the cluster node groups"
