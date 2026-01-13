#!/bin/bash
set -o nounset
set -o errexit
set -o pipefail

# save the exit code for junit xml file generated in step gather-must-gather
# pre configuration steps before running installation, exit code 100 if failed,
# save to install-pre-config-status.txt
# post check steps after cluster installation, exit code 101 if failed,
# save to install-post-check-status.txt
EXIT_CODE=100
trap 'if [[ "$?" == 0 ]]; then EXIT_CODE=0; fi; echo "${EXIT_CODE}" > "${SHARED_DIR}/install-post-check-status.txt"' EXIT TERM

export AWS_SHARED_CREDENTIALS_FILE="${CLUSTER_PROFILE_DIR}/.awscred"
REGION="${LEASED_RESOURCE}"
CLUSTER_NAME="${NAMESPACE}-${UNIQUE_HASH}"
EXPIRATION_DATE=$(date -d '12 hours' --iso=minutes --utc)

if ((AWS_DH_MINIMUM_HOST_NUMBER > AWS_DH_REQUIRED_HOST_NUMBER)); then
    echo "Error: AWS_DH_MINIMUM_HOST_NUMBER ($AWS_DH_MINIMUM_HOST_NUMBER) cannot be greater than AWS_DH_REQUIRED_HOST_NUMBER ($AWS_DH_REQUIRED_HOST_NUMBER)"
    exit 1
fi

# --------------------------------------------------------------
# Existing Dedicated Hosts
# --------------------------------------------------------------

if [[ "$AWS_DH_EXISTING_DH_POOL" != "" ]]; then

    echo "Using existing Dedicated Host"

    # random order
    DH_POOL=$(echo "$AWS_DH_EXISTING_DH_POOL" | tr ' ' '\n' | shuf | tr '\n' ' ' | sed 's/ $/\n/')
    for HOST_ID in $DH_POOL;
    do
        echo "Checking $HOST_ID ..."
        aws ec2 describe-hosts --region "$REGION" --host-ids "$HOST_ID" > /tmp/dh.json
        CURRENT_TYPE=$(jq -r '.Hosts[].HostProperties.InstanceType' /tmp/dh.json)
        AZ=$(jq -r '.Hosts[].AvailabilityZone' /tmp/dh.json)
        TYPE_VCPU=$(aws --region "$REGION" ec2 describe-instance-types --instance-types "$CURRENT_TYPE" | jq -r '.InstanceTypes[].VCpuInfo.DefaultVCpus')
        AVAILABLE_VCPUS=$(jq -r '.Hosts[].AvailableCapacity.AvailableVCpus' /tmp/dh.json)

        echo "Type: $CURRENT_TYPE"
        echo "AZ: $AZ"
        echo "TYPE_VCPU: $TYPE_VCPU"
        echo "AVAILABLE_VCPUS: $AVAILABLE_VCPUS"

        TOTAL_INSTANCE_COUNT=1 # bootstrap

        if [[ "$JOB_NAME" == *"-sno-"* ]]; then
            # SNO cluster
            TOTAL_INSTANCE_COUNT=$((TOTAL_INSTANCE_COUNT+1))
        else
            TOTAL_INSTANCE_COUNT=$((TOTAL_INSTANCE_COUNT+${CONTROL_PLANE_REPLICAS:-3})) # control plane nodes
            if [[ "${SIZE_VARIANT:-}" != "compact" ]]; then
                TOTAL_INSTANCE_COUNT=$((TOTAL_INSTANCE_COUNT+${COMPUTE_NODE_REPLICAS:-3})) # compute nodes
            fi
        fi

        echo "TOTAL_INSTANCE_COUNT: $TOTAL_INSTANCE_COUNT"

        if ((TYPE_VCPU*TOTAL_INSTANCE_COUNT < AVAILABLE_VCPUS)); then
            echo "Selected existing Dedicated Host $HOST_ID"
            cp /tmp/dh.json "${SHARED_DIR}"/selected_dedicated_hosts.json
            exit 0
        fi
    done
    # exit directly, as we won't allocate Dedicated Hosts dynamic
    echo "ERROR: No available existing Dedicated Host for procisioning cluster."
    exit 1
fi

# --------------------------------------------------------------
# Dynamic allocate Dedicated Hosts
# --------------------------------------------------------------

trap 'destroy_allocated_unused_hosts' EXIT TERM

function destroy_allocated_unused_hosts()
{
    echo -e "Destroying allocated but not used Dedicated Hosts..."
    if [ -f "${SHARED_DIR}"/allocated_but_not_used_dedicated_host.txt ]; then
        while IFS= read -r HOST_ID; do
            echo "  Releasing host: $HOST_ID"
            aws ec2 release-hosts --region "$REGION" --host-ids "$HOST_ID"
        done < "${SHARED_DIR}"/allocated_but_not_used_dedicated_host.txt
    fi
}

# Retry function with Full Jitter exponential backoff
# Reference: https://aws.amazon.com/blogs/architecture/exponential-backoff-and-jitter/
# Full Jitter provides the best results by selecting a random sleep time between 0 and the exponential backoff cap
retry_with_backoff()
{
    local command="$1"
    local retry_count=0
    local exit_code=0

    while [ $retry_count -lt $AWS_DH_MAX_RETRIES ]; do
        # Execute the command and capture both stdout and stderr
        local output

        output=$(eval "$command" 2>&1)
        exit_code=$?

        # Check if command succeeded
        if [ $exit_code -eq 0 ]; then
            echo "$output"
            return 0
        fi

        # Check if error is retryable (InsufficientHostCapacity)
        if echo "$output" | grep -q "InsufficientHostCapacity"; then
            retry_count=$((retry_count + 1))

            if [ $retry_count -ge $AWS_DH_MAX_RETRIES ]; then
                echo -e "  ✗ Max retries ($AWS_DH_MAX_RETRIES) reached. Last error:" >&2
                echo "$output" >&2
                echo "RETRIED:$retry_count"  # Signal that retries occurred
                return $exit_code
            fi

            # Calculate exponential backoff with Full Jitter
            # Formula: sleep = random_between(0, min(AWS_DH_MAX_BACKOFF, AWS_DH_BASE_BACKOFF * 2^attempt))
            local exp_backoff=$((AWS_DH_BASE_BACKOFF * (2 ** retry_count)))
            local capped_backoff=$((exp_backoff > AWS_DH_MAX_BACKOFF ? AWS_DH_MAX_BACKOFF : exp_backoff))

            # Generate random jitter between 0 and capped_backoff (Full Jitter)
            local sleep_time=$((RANDOM % (capped_backoff + 1)))

            echo -e "  ⚠ InsufficientHostCapacity detected. Retry $retry_count/$AWS_DH_MAX_RETRIES after ${sleep_time}s (Full Jitter)..." >&2
            sleep $sleep_time
        else
            # Non-retryable error - return immediately with error details
            echo "$output" >&2
            echo "ERROR_TYPE:NON_RETRYABLE"  # Signal that no retries occurred
            return $exit_code
        fi
    done

    return $exit_code
}

# Determine which instance types will be used
if [ "$CONTROL_PLANE_INSTANCE_TYPE" == "" ] && [ "$COMPUTE_NODE_TYPE" == "" ]; then
    CANDIDATE_TYPES="$AWS_DH_CANDIDATE_TYPES"
else
    echo "CONTROL_PLANE_INSTANCE_TYPE/COMPUTE_NODE_TYPE is set, using specified instance type."
    if [ "$CONTROL_PLANE_INSTANCE_TYPE" == "$COMPUTE_NODE_TYPE" ]; then
        CANDIDATE_TYPES="$CONTROL_PLANE_INSTANCE_TYPE"
    else
        echo "ERROR: CONTROL_PLANE_INSTANCE_TYPE($CONTROL_PLANE_INSTANCE_TYPE)/COMPUTE_NODE_TYPE($COMPUTE_NODE_TYPE) are set, but they are not identical."
        exit 1
    fi
fi

echo -e "=== AWS Dedicated Host Multi-AZ Allocation ==="
echo "Region: $REGION"
echo "Candidate Instance Types: $CANDIDATE_TYPES"
echo "Minimum Requirement: $AWS_DH_MINIMUM_HOST_NUMBER hosts (same type)"
if [ -n "$AWS_DH_REQUIRED_HOST_NUMBER" ]; then
    echo "Maximum Allocations: $AWS_DH_REQUIRED_HOST_NUMBER hosts"
fi
echo "Retry Strategy: Full Jitter (Max retries: $AWS_DH_MAX_RETRIES, Base backoff: ${AWS_DH_BASE_BACKOFF}s, Max backoff: ${AWS_DH_MAX_BACKOFF}s)"
echo ""

if [ -f "${SHARED_DIR}"/vpc_info.json ]; then
    # byo vpc
    echo -e "Fetching Availability Zones from BYO-VPC"
    AVAILABILITY_ZONES=$(jq -r '[.subnets[].az] | join(" ")' "${SHARED_DIR}"/vpc_info.json)
else
    echo -e "Fetching available Availability Zones..."
    AVAILABILITY_ZONES=$(aws ec2 describe-availability-zones \
        --region "$REGION" \
        --filters "Name=state,Values=available" "Name=zone-type,Values=availability-zone" \
        --query 'AvailabilityZones[].ZoneName' \
        --output text)
fi

if [ -z "$AVAILABILITY_ZONES" ]; then
    echo -e "Error: No available AZs found in region $REGION"
    exit 1
fi

echo "Available AZs: $AVAILABILITY_ZONES"
echo ""

HOST_IDS=()
ALLOCATION_SUMMARY=()
USED_AZS=()
REQUIRED_REACHED=false  # Flag to stop when AWS_DH_REQUIRED_HOST_NUMBER is reached
MINIMUM_REACHED=false  # Flag to stop when AWS_DH_MINIMUM_HOST_NUMBER is reached
ALLOCATED_TYPE=""  # Track which instance type was successfully allocated

# Try each candidate instance type until minimum requirement is met
for CURRENT_TYPE in $CANDIDATE_TYPES; do

    # ----------------------------------------------------------------------------------------------
    # Verify instance type availability in each AZ, not all instance types are available in all AZs.
    # ----------------------------------------------------------------------------------------------
    echo -e "=== Trying instance type: $CURRENT_TYPE ==="
    AVAILABLE_AZS="$AVAILABILITY_ZONES" # Reset AZ list for each instance type
    echo -e "Verifying instance type availability in each AZ..."
    for AZ in $AVAILABILITY_ZONES; do
        AVAILABLE=$(aws ec2 describe-instance-type-offerings \
            --region "$REGION" \
            --location-type "availability-zone" \
            --filters "Name=location,Values=$AZ" "Name=instance-type,Values=$CURRENT_TYPE" \
            --query 'InstanceTypeOfferings[0].InstanceType' \
            --output text 2>/dev/null || echo "None")

        if [ "$AVAILABLE" = "$CURRENT_TYPE" ]; then
            echo -e "  ✓ $AZ: $CURRENT_TYPE available"
        else
            echo -e "  ✗ $AZ: $CURRENT_TYPE NOT available (skipping)"
            AVAILABLE_AZS=$(echo "$AVAILABLE_AZS" | sed "s/$AZ//g")
        fi
    done
    echo ""

    # Skip this instance type if not available in any AZ
    if [ -z "$AVAILABLE_AZS" ]; then
        echo -e "⚠ $CURRENT_TYPE not available in any AZ, trying next instance type..."
        echo ""
        continue
    fi

    # ----------------------------------------------------------------------------------------------
    # Allocate hosts across AZs
    # ----------------------------------------------------------------------------------------------
    # This provides redundancy and fault tolerance
    echo -e "Allocating Dedicated Hosts across AZs..."

    for AZ in $AVAILABLE_AZS; do
        echo -e "Processing: [$AZ] [$CURRENT_TYPE]"

        cat <<EOF > /tmp/tag_spec.json
[
  {
    "ResourceType": "dedicated-host",
    "Tags": [
      {"Key": "Name", "Value": "${CLUSTER_NAME}-${AZ}-${CURRENT_TYPE}"},
      {"Key": "CI-JOB", "Value": "${JOB_NAME_SAFE}"},
      {"Key": "expirationDate", "Value": "${EXPIRATION_DATE}"},
      {"Key": "ci-build-info", "Value": "${BUILD_ID}_${JOB_NAME}"}
    ]
  }
]
EOF
        ALLOC_CMD="aws ec2 allocate-hosts \
            --region $REGION \
            --instance-type $CURRENT_TYPE \
            --availability-zone $AZ \
            --auto-placement $AWS_DH_AUTO_PLACEMENT \
            --host-recovery $AWS_DH_HOST_RECOVERY \
            --quantity 1 \
            --tag-specifications file:///tmp/tag_spec.json \
            --output json"

        # exponential backoff, this handles InsufficientHostCapacity errors gracefully
        set +e

        RESULT=$(retry_with_backoff "$ALLOC_CMD")
        exit_code=$?

        if [ $exit_code -eq 0 ]; then
            # Filter out the success JSON from any retry messages
            HOST_ID=$(echo "$RESULT" | grep -v "^RETRIED:" | grep -v "^ERROR_TYPE:" | jq -r '.HostIds[0]')
            HOST_IDS+=("$HOST_ID")
            ALLOCATION_SUMMARY+=("$AZ ($CURRENT_TYPE): $HOST_ID")

            # Track the AZ and host ID for YAML output, store as "HOST_ID:AZ" for later processing
            USED_AZS+=("$HOST_ID:$AZ")

            ALLOCATED_TYPE="$CURRENT_TYPE"
            echo -e "  ✓ Allocated: $HOST_ID ($CURRENT_TYPE in $AZ)"

            # Check if minimum requirement reached
            if [ ${#HOST_IDS[@]} -ge $AWS_DH_MINIMUM_HOST_NUMBER ]; then
                MINIMUM_REACHED=true
            fi

            if [ -n "$AWS_DH_REQUIRED_HOST_NUMBER" ] && [ ${#HOST_IDS[@]} -ge $AWS_DH_REQUIRED_HOST_NUMBER ]; then
                REQUIRED_REACHED=true
            fi
        else
            # Check if retries occurred or if it was a non-retryable error
            if echo "$RESULT" | grep -q "^ERROR_TYPE:NON_RETRYABLE"; then
                # Extract the actual error message
                ERROR_MSG=$(echo "$RESULT" | grep -v "^ERROR_TYPE:" | tail -1)

                # Check for specific error types
                if echo "$ERROR_MSG" | grep -q "HostLimitExceeded"; then
                    echo -e "  ✗ Failed: HostLimitExceeded - You have reached your Dedicated Host quota limit"
                    echo -e "      → Request a quota increase via AWS Service Quotas or try a different instance type"
                elif echo "$ERROR_MSG" | grep -q "InsufficientHostCapacity"; then
                    echo -e "  ✗ Failed: InsufficientHostCapacity - No capacity available"
                else
                    echo -e "  ✗ Failed to allocate host in $AZ"
                fi
            else
                # Retries occurred (InsufficientHostCapacity)
                echo -e "  ✗ Failed to allocate host in $AZ after $AWS_DH_MAX_RETRIES retries (InsufficientHostCapacity)"
            fi
            # Continue with other AZs instead of failing completely
        fi

        set -e

        # Check if AWS_DH_MINIMUM_HOST_NUMBER or AWS_DH_REQUIRED_HOST_NUMBER was reached during this AZ's allocation
        if [ "$REQUIRED_REACHED" = true ]; then
            echo ""
            break  # Exit AZ loop immediately
        fi

        echo ""
    done

    # Check if minimum requirement is met
    echo -e "Current total: ${#HOST_IDS[@]} hosts allocated (type: ${ALLOCATED_TYPE})"

    if [ "$REQUIRED_REACHED" = true ]; then
        echo -e "✓ Required $AWS_DH_REQUIRED_HOST_NUMBER hosts met (all from $ALLOCATED_TYPE)!"
        echo ""
        break # Exit instance type loop immediately
    fi
    
    if [ "$MINIMUM_REACHED" = true ]; then
        echo -e "✓ Minimum requirement of $AWS_DH_MINIMUM_HOST_NUMBER hosts met (all from $ALLOCATED_TYPE)!"
        echo ""
        break # Exit instance type loop immediately
    else
        echo -e "⚠ Need at least $AWS_DH_MINIMUM_HOST_NUMBER hosts from same type, trying next instance type..."
        echo ""

        # Save host info for destroying
        echo "Saving allocated but not used host info for cleanup..."
        for HOST_ID in "${HOST_IDS[@]}"; do
            echo "$HOST_ID" >> "${SHARED_DIR}"/allocated_but_not_used_dedicated_host.txt
        done

        # Reset for next instance type attempt (including both flags)
        HOST_IDS=()
        ALLOCATION_SUMMARY=()
        USED_AZS=()
        ALLOCATED_TYPE=""
        REQUIRED_REACHED=false
        MINIMUM_REACHED=false
    fi
done

# EXIT if no hosts allocated
if [ ${#HOST_IDS[@]} -eq 0 ]; then
    echo -e "=== Error: No hosts were successfully allocated ==="
    exit 1
fi

if [ "$MINIMUM_REACHED" != true ]; then
    echo -e "=== Error: Minimum requirement not met ==="
    echo "Allocated ${#HOST_IDS[@]} hosts, but minimum requirement is $AWS_DH_MINIMUM_HOST_NUMBER (same type)"
    echo "All candidate instance types have been exhausted."
    echo ""
    exit 1
fi

echo -e "Waiting for hosts to become available..."
MAX_WAIT=300  # 5 minutes
ELAPSED=0

while [ $ELAPSED -lt $MAX_WAIT ]; do
    ALL_AVAILABLE=true

    for HOST_ID in "${HOST_IDS[@]}"; do
        STATE=$(aws ec2 describe-hosts \
            --region "$REGION" \
            --host-ids "$HOST_ID" \
            --query 'Hosts[0].State' \
            --output text)

        if [ "$STATE" != "available" ]; then
            ALL_AVAILABLE=false
            break
        fi
    done

    if [ "$ALL_AVAILABLE" = true ]; then
        echo -e "All hosts are available!"
        break
    fi

    echo "  Waiting... ($ELAPSED seconds elapsed)"
    sleep 10
    ELAPSED=$((ELAPSED + 10))
done

# EXIT if not all hosts are ready
if [ $ELAPSED -ge $MAX_WAIT ]; then
    echo -e "ERROR: Timeout waiting for hosts to become available"
    exit 1
fi

echo ""
echo -e "=== Allocation Summary ==="
echo "Total hosts allocated: ${#HOST_IDS[@]}"
echo ""
if [ ${#ALLOCATION_SUMMARY[@]} -gt 0 ]; then
    for SUMMARY in "${ALLOCATION_SUMMARY[@]}"; do
        echo "  $SUMMARY"
    done
else
    echo "  No hosts were successfully allocated"
fi
echo ""

# Output host details
if [ ${#HOST_IDS[@]} -gt 0 ]; then
    echo -e "Detailed host information..."
    echo ""

    aws ec2 describe-hosts \
        --region "$REGION" \
        --host-ids "${HOST_IDS[@]}" \
        --output json > "${SHARED_DIR}"/selected_dedicated_hosts.json
    
    cp "${SHARED_DIR}"/selected_dedicated_hosts.json "${SHARED_DIR}"/dedicated_hosts_to_be_removed.json
    echo "Selected Dedicated Hosts:"
    jq 'del(.Hosts[].OwnerId)' "${SHARED_DIR}"/selected_dedicated_hosts.json
fi

echo ""
