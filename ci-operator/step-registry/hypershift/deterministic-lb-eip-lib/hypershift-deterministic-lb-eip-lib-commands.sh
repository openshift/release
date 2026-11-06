#!/bin/bash

set -euo pipefail

LIB_FILE="${SHARED_DIR}/deterministic-lb-eip-lib.sh"

cat > "${LIB_FILE}" <<'EOF'
EIP_RUN_TAG="HypershiftE2ERun"

aws_cmd() {
    aws --region "${MGMT_REGION}" "$@"
}

# Find an EIP that this execution definitely owns. The shared Name tag is
# deliberately not used: a retry may recover an allocation made before
# eip.env was written, but it must never adopt another execution's address.
find_run_eip() {
    local allocations
    if ! allocations=$(aws_cmd ec2 describe-addresses \
        --filters "Name=tag:${EIP_RUN_TAG},Values=${RUN_ID}" \
        --query 'Addresses[].AllocationId' --output text); then
        echo "failed to list EIPs for ${EIP_RUN_TAG}=${RUN_ID}" >&2
        return 1
    fi

    if [[ -z "${allocations}" || "${allocations}" == "None" ]]; then
        return 0
    fi

    local -a allocation_ids
    read -r -a allocation_ids <<< "${allocations}"
    if [[ ${#allocation_ids[@]} -ne 1 ]]; then
        echo "expected one EIP tagged ${EIP_RUN_TAG}=${RUN_ID}, found ${#allocation_ids[@]}" >&2
        return 1
    fi

    printf '%s\n' "${allocation_ids[0]}"
}

# Verify that an allocation referenced by eip.env belongs to this execution.
# Return 2 when AWS reports the allocation as already gone so cleanup can be
# idempotent; return 1 for any other lookup failure.
verify_run_eip() {
    local allocation_id="$1"
    local owner
    if ! owner=$(aws_cmd ec2 describe-addresses --allocation-ids "${allocation_id}" \
        --query "Addresses[0].Tags[?Key==\`${EIP_RUN_TAG}\`].Value | [0]" --output text 2>&1); then
        if [[ "${owner}" == *InvalidAllocationID.NotFound* ]]; then
            return 2
        fi
        echo "failed to describe EIP ${allocation_id}" >&2
        return 1
    fi
    if [[ "${owner}" != "${RUN_ID}" ]]; then
        echo "EIP ${allocation_id} is tagged ${EIP_RUN_TAG}=${owner}, not ${RUN_ID}" >&2
        return 1
    fi
}
EOF

chmod 600 "${LIB_FILE}"
echo "wrote ${LIB_FILE}"
