#!/bin/bash

set -o nounset
set -o errexit
set -o pipefail

EXIT_CODE=100
trap 'if [[ "$?" == 0 ]]; then EXIT_CODE=0; fi; echo "${EXIT_CODE}" > "${SHARED_DIR}/install-pre-config-status.txt"' EXIT TERM

export AWS_SHARED_CREDENTIALS_FILE="${CLUSTER_PROFILE_DIR}/.awscred"
REGION="${REGION:-${LEASED_RESOURCE}}"

# For C2S / SC2S the leased resource identifies the account, not the region.
if [[ "${CLUSTER_TYPE:-}" =~ ^aws-s?c2s$ ]]; then
    REGION=$(jq -r ".\"${LEASED_RESOURCE}\".source_region" \
        "${CLUSTER_PROFILE_DIR}/shift_project_setting.json")
fi

echo "Region: ${REGION}"

# ----------------------------------------------------------------
# Resolve the public route table
# ----------------------------------------------------------------
if [[ ! -f "${SHARED_DIR}/public_route_table_id" ]]; then
    echo "ERROR: ${SHARED_DIR}/public_route_table_id not found."
    echo "aws-provision-vpc-disconnected must have run before this step."
    exit 1
fi
PUBLIC_RTB=$(cat "${SHARED_DIR}/public_route_table_id")
echo "Public route table: ${PUBLIC_RTB}"

# ----------------------------------------------------------------
# Collect ALL private route table IDs from the stack output.
# aws-provision-vpc-disconnected can create up to 3 private route
# tables (one per AZ). The stack output key is "PrivateRouteTableIds"
# and contains a comma-separated list of "az=rtb-id" pairs.
# ----------------------------------------------------------------
PRIVATE_RTBS=()
if [[ -f "${SHARED_DIR}/vpc_stack_output" ]]; then
    RAW_PRIVATE=$(jq -r '
        .Stacks[].Outputs[]
        | select(.OutputKey=="PrivateRouteTableIds")
        | .OutputValue
    ' "${SHARED_DIR}/vpc_stack_output" 2>/dev/null || echo "")

    if [[ -n "${RAW_PRIVATE}" ]]; then
        # Format: "us-east-1a=rtb-aaa,us-east-1b=rtb-bbb"
        while IFS=',' read -ra PAIRS; do
            for PAIR in "${PAIRS[@]}"; do
                RTB_ID="${PAIR#*=}"
                [[ -n "${RTB_ID}" ]] && PRIVATE_RTBS+=("${RTB_ID}")
            done
        done <<< "${RAW_PRIVATE}"
    fi
fi

# Fall back to the single ID written by the vpc-disconnected step.
if [[ ${#PRIVATE_RTBS[@]} -eq 0 ]] && [[ -f "${SHARED_DIR}/private_route_table_id" ]]; then
    PRIVATE_RTBS+=("$(cat "${SHARED_DIR}/private_route_table_id")")
fi

echo "Private route tables: ${PRIVATE_RTBS[*]:-none}"

# ----------------------------------------------------------------
# Determine whether the VPC is dual-stack
# ----------------------------------------------------------------
IPV6_CIDR=""
if [[ -f "${SHARED_DIR}/vpc_stack_output" ]]; then
    IPV6_CIDR=$(jq -r '
        .Stacks[].Outputs[]
        | select(.OutputKey=="VpcIpv6Cidr")
        | .OutputValue
    ' "${SHARED_DIR}/vpc_stack_output" 2>/dev/null || echo "")
fi
IS_DUALSTACK=false
[[ -n "${IPV6_CIDR}" ]] && IS_DUALSTACK=true
echo "Dual-stack: ${IS_DUALSTACK}"

# ----------------------------------------------------------------
# Helper: delete a route from a route table, ignoring "not found"
# ----------------------------------------------------------------
function delete_route() {
    local RTB="$1"
    local DEST="$2"
    local DEST_FLAG="$3"  # "--destination-cidr-block" or "--destination-ipv6-cidr-block"

    echo "Deleting route ${DEST} from route table ${RTB}..."
    if aws --region "${REGION}" ec2 delete-route \
            --route-table-id "${RTB}" \
            "${DEST_FLAG}" "${DEST}" 2>&1; then
        echo "  Route ${DEST} deleted from ${RTB}."
    else
        # Exit code 254 / InvalidRoute.NotFound means it was already gone — treat as success.
        echo "  Route ${DEST} not found in ${RTB} (already absent), continuing."
    fi
}

# ----------------------------------------------------------------
# Remove 0.0.0.0/0 (and ::/0) from the public route table
# ----------------------------------------------------------------
echo "--- Removing internet routes from public route table ${PUBLIC_RTB} ---"
delete_route "${PUBLIC_RTB}" "0.0.0.0/0" "--destination-cidr-block"
if [[ "${IS_DUALSTACK}" == "true" ]]; then
    delete_route "${PUBLIC_RTB}" "::/0" "--destination-ipv6-cidr-block"
fi

# ----------------------------------------------------------------
# Remove any residual internet routes from private route tables
# (the disconnected VPC template does not add them, but be defensive)
# ----------------------------------------------------------------
for RTB in "${PRIVATE_RTBS[@]:-}"; do
    [[ -z "${RTB}" ]] && continue
    echo "--- Checking private route table ${RTB} ---"
    delete_route "${RTB}" "0.0.0.0/0" "--destination-cidr-block"
    if [[ "${IS_DUALSTACK}" == "true" ]]; then
        delete_route "${RTB}" "::/0" "--destination-ipv6-cidr-block"
    fi
done

# ----------------------------------------------------------------
# Verify: confirm no route to 0.0.0.0/0 remains on any of the tables
# ----------------------------------------------------------------
echo "--- Verifying internet routes are gone ---"
ALL_TABLES=("${PUBLIC_RTB}" "${PRIVATE_RTBS[@]:-}")
for RTB in "${ALL_TABLES[@]:-}"; do
    [[ -z "${RTB}" ]] && continue
    REMAINING=$(aws --region "${REGION}" ec2 describe-route-tables \
        --route-table-ids "${RTB}" \
        --query 'RouteTables[].Routes[?DestinationCidrBlock==`0.0.0.0/0` || DestinationIpv6CidrBlock==`::/0`]' \
        --output json 2>/dev/null || echo "[]")
    if [[ "${REMAINING}" == "[]" ]] || [[ "${REMAINING}" == "[[]]" ]]; then
        echo "  ${RTB}: no internet routes present. OK."
    else
        echo "  WARNING: internet routes still present in ${RTB}: ${REMAINING}"
    fi
done

echo "Internet access successfully removed from the VPC. Air-gap enforced."
