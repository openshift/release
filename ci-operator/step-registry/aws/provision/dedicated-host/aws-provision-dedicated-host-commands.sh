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
trap 'destroy_allocated_unused_hosts; if [[ "$?" == 0 ]]; then EXIT_CODE=0; fi; echo "${EXIT_CODE}" > "${SHARED_DIR}/install-pre-config-status.txt"' EXIT TERM


export AWS_SHARED_CREDENTIALS_FILE="${CLUSTER_PROFILE_DIR}/.awscred"
REGION="${LEASED_RESOURCE}"
CLUSTER_NAME="${NAMESPACE}-${UNIQUE_HASH}"
EXPIRATION_DATE=$(date -d '12 hours' --iso=minutes --utc)

echo "CONTROL_PLANE_INSTANCE_TYPE: $CONTROL_PLANE_INSTANCE_TYPE"
echo "COMPUTE_NODE_TYPE: $COMPUTE_NODE_TYPE"
echo "DEFAULT_INSTANCE_TYPE: $DEFAULT_INSTANCE_TYPE"
echo "AWS_DH_REQUIRED_HOST_NUMBER: $AWS_DH_REQUIRED_HOST_NUMBER"
echo "AWS_DH_CANDIDATE_TYPES: $AWS_DH_CANDIDATE_TYPES"
echo "AWS_DH_SHARE_FOR_ALL_NODES: $AWS_DH_SHARE_FOR_ALL_NODES"
echo "AWS_DH_AUTO_PLACEMENT: $AWS_DH_AUTO_PLACEMENT"
echo "AWS_DH_HOST_RECOVERY: $AWS_DH_HOST_RECOVERY"
echo "AWS_DH_MAX_RETRIES: $AWS_DH_MAX_RETRIES"
echo "AWS_DH_BASE_BACKOFF: $AWS_DH_BASE_BACKOFF"
echo "AWS_DH_MAX_BACKOFF: $AWS_DH_MAX_BACKOFF"

# --------------------------------------------------------------
# Dynamic allocate Dedicated Hosts
# --------------------------------------------------------------

function destroy_allocated_unused_hosts()
{
    echo -e "Destroying allocated but not used Dedicated Hosts..."
    if [ -s "${SHARED_DIR}"/allocated_but_not_used_dedicated_host.txt ]; then
        while IFS= read -r HOST_ID; do
            echo "  Releasing host: $HOST_ID"
            aws ec2 release-hosts --region "$REGION" --host-ids "$HOST_ID"
        done < "${SHARED_DIR}"/allocated_but_not_used_dedicated_host.txt
    fi
}

# Retry function with Full Jitter exponential backoff
# Reference: https://aws.amazon.com/blogs/architecture/exponential-backoff-and-jitter/
# Full Jitter provides the best results by selecting a random sleep time between 0 and the exponential backoff cap
function retry_with_backoff()
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


function aws_allocate_host()
{
    local instance_type="$1"
    local zone="$2"

    cat <<EOF > /tmp/tag_spec.json
[
  {
    "ResourceType": "dedicated-host",
    "Tags": [
      {"Key": "Name", "Value": "${CLUSTER_NAME}-${zone}-${instance_type}"},
      {"Key": "CI-JOB", "Value": "${JOB_NAME_SAFE}"},
      {"Key": "expirationDate", "Value": "${EXPIRATION_DATE}"},
      {"Key": "ci-build-info", "Value": "${BUILD_ID}_${JOB_NAME}"}
    ]
  }
]
EOF
    local alloc_cmd

    alloc_cmd="aws ec2 allocate-hosts \
        --region $REGION \
        --instance-type $instance_type \
        --availability-zone $zone \
        --auto-placement $AWS_DH_AUTO_PLACEMENT \
        --host-recovery $AWS_DH_HOST_RECOVERY \
        --quantity 1 \
        --tag-specifications file:///tmp/tag_spec.json \
        --output json"

        # exponential backoff, this handles InsufficientHostCapacity errors gracefully
        retry_with_backoff "$alloc_cmd"
}

function instance_type_is_available()
{
    local instance_type=$1
    local zone=$2

    local result
    result=$(aws ec2 describe-instance-type-offerings \
            --region "$REGION" \
            --location-type "availability-zone" \
            --filters "Name=location,Values=$zone" "Name=instance-type,Values=$instance_type" \
            --query 'InstanceTypeOfferings[0].InstanceType' \
            --output text 2>/dev/null)

    if [[ "$result" == "None" ]]; then
        return 1
    fi
    return 0
}

function provision_dh()
{
    local machine_types="$1"
    local info_file="$2"

    local HOST_ID HOST_IDS REQUIRED_REACHED
    HOST_IDS=()
    REQUIRED_REACHED=false  # Flag to stop when AWS_DH_REQUIRED_HOST_NUMBER is reached

    for type in $machine_types; do

        echo -e "--------------------------------------"
        echo -e "Allocating Dedicated Hosts for [$type]"
        echo -e "--------------------------------------"

        for AZ in $AVAILABILITY_ZONES; do

            if ! instance_type_is_available "$type" "$AZ"; then
                echo -e "✗ $AZ: $type is NOT available (skipping)"
                continue
            fi

            echo -e "✓ $AZ: $type is available"
            echo -e "Allocating DH [$type] on [$AZ] ..."

            set +e

            local RESULT allocate_ret
            RESULT=$(aws_allocate_host "$type" "$AZ")
            allocate_ret=$?

            if [ $allocate_ret -eq 0 ]; then
                # Filter out the success JSON from any retry messages
                HOST_ID=$(echo "$RESULT" | grep -v "^RETRIED:" | grep -v "^ERROR_TYPE:" | jq -r '.HostIds[0]')
                HOST_IDS+=("$HOST_ID")

                echo -e "  ✓ Allocated: $HOST_ID ($type in $AZ)"

                # Check if AWS_DH_REQUIRED_HOST_NUMBER is reached.
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
        done # AZ loop

        if [ "$REQUIRED_REACHED" = true ]; then
            echo -e "✓ Required $AWS_DH_REQUIRED_HOST_NUMBER hosts met (all from $type)!"
            echo ""
            break # Exit instance type loop immediately
        else
            echo -e "⚠ Need $AWS_DH_REQUIRED_HOST_NUMBER hosts from same type, trying next instance type..."
            echo ""

            # Save host info for destroying
            echo "Saving allocated but not used host info for cleanup..."
            for HOST_ID in "${HOST_IDS[@]}"; do
                echo "$HOST_ID" >> "${SHARED_DIR}"/allocated_but_not_used_dedicated_host.txt
            done

            # reset
            HOST_IDS=()
            REQUIRED_REACHED=false  # Flag to stop when AWS_DH_REQUIRED_HOST_NUMBER is reached
        fi
    done # machine types


    if [ ${#HOST_IDS[@]} -eq 0 ]; then
        echo -e "=== Error: No hosts were successfully allocated ==="
        return 1
    fi

    echo -e "Waiting for hosts to become available..."
    local MAX_WAIT ELAPSED STATE ALL_AVAILABLE
    MAX_WAIT=300  # 5 minutes
    ELAPSED=0
    ALL_AVAILABLE=true

    while [ $ELAPSED -lt $MAX_WAIT ]; do
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
        echo -e "ERROR: Timeout waiting for hosts to become available, the hosts will be removed."
        for HOST_ID in "${HOST_IDS[@]}"; do
            echo "$HOST_ID" >> "${SHARED_DIR}"/allocated_but_not_used_dedicated_host.txt
        done
        return 1
    fi

    # save DH info
    # Output host details
    if [ ${#HOST_IDS[@]} -gt 0 ]; then
        echo -e "Detailed host information..."
        echo ""

        aws ec2 describe-hosts \
            --region "$REGION" \
            --host-ids "${HOST_IDS[@]}" \
            --output json > "${info_file}"

        echo "Selected Dedicated Hosts:"
        jq 'del(.Hosts[].OwnerId)' "${info_file}"
    fi
    echo ""
}


# --------------------------------------------
# Get all AVAILABILITY ZONES
# --------------------------------------------
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

# --------------------------------------------
# Validate instance type configuration when sharing is enabled
# --------------------------------------------
provisioned_dh_file=/tmp/provisioned_dh_info.json
touch "$provisioned_dh_file"

if [[ "$AWS_DH_SHARE_FOR_ALL_NODES" == "yes" ]]; then
    echo "======================================"
    echo "AWS_DH_SHARE_FOR_ALL_NODES is enabled"
    echo "AWS_DEDICATED_HOST_APPLY_TO: $AWS_DEDICATED_HOST_APPLY_TO"
    echo "======================================"

    # Count how many node types are in AWS_DEDICATED_HOST_APPLY_TO
    node_type_count=0
    if [[ "$AWS_DEDICATED_HOST_APPLY_TO" == *"controlPlane"* ]]; then
        node_type_count=$((node_type_count + 1))
    fi
    if [[ "$AWS_DEDICATED_HOST_APPLY_TO" == *"compute"* ]]; then
        node_type_count=$((node_type_count + 1))
    fi
    if [[ "$AWS_DEDICATED_HOST_APPLY_TO" == *"default"* ]]; then
        node_type_count=$((node_type_count + 1))
    fi

    # Informational message if only one node type (sharing is harmless but has no effect)
    if [ $node_type_count -lt 2 ]; then
        echo "ℹ Note: AWS_DH_SHARE_FOR_ALL_NODES=yes with only $node_type_count node type"
        echo "  Sharing has no effect when provisioning for a single node type"
        echo "  Proceeding with normal provisioning..."
        echo ""
    else
        # Only validate when there are 2+ node types (when sharing actually matters)
        # When sharing is enabled, ALL applicable node types must have instance types explicitly set
        declare -a required_types
        declare -a missing_types

        required_types=()
        missing_types=()

        if [[ "$AWS_DEDICATED_HOST_APPLY_TO" == *"controlPlane"* ]]; then
            if [[ -n "$CONTROL_PLANE_INSTANCE_TYPE" ]]; then
                required_types+=("CONTROL_PLANE:$CONTROL_PLANE_INSTANCE_TYPE")
            else
                missing_types+=("CONTROL_PLANE_INSTANCE_TYPE")
            fi
        fi

        if [[ "$AWS_DEDICATED_HOST_APPLY_TO" == *"compute"* ]]; then
            if [[ -n "$COMPUTE_NODE_TYPE" ]]; then
                required_types+=("COMPUTE:$COMPUTE_NODE_TYPE")
            else
                missing_types+=("COMPUTE_NODE_TYPE")
            fi
        fi

        if [[ "$AWS_DEDICATED_HOST_APPLY_TO" == *"default"* ]]; then
            if [[ -n "$DEFAULT_INSTANCE_TYPE" ]]; then
                required_types+=("DEFAULT:$DEFAULT_INSTANCE_TYPE")
            else
                missing_types+=("DEFAULT_INSTANCE_TYPE")
            fi
        fi

        # Check if any required instance types are missing
        if [ ${#missing_types[@]} -gt 0 ]; then
            echo "✗ Error: When AWS_DH_SHARE_FOR_ALL_NODES=yes, all instance types must be explicitly set"
            echo ""
            echo "  Missing instance type configuration:"
            for missing in "${missing_types[@]}"; do
                echo "    - $missing"
            done
            echo ""
            echo "  Required: All node types in AWS_DEDICATED_HOST_APPLY_TO must have instance types explicitly configured"
            echo "  Example:"
            echo "    export CONTROL_PLANE_INSTANCE_TYPE=m5.2xlarge"
            echo "    export COMPUTE_NODE_TYPE=m5.2xlarge"
            echo "    export DEFAULT_INSTANCE_TYPE=m5.2xlarge"
            exit 1
        fi

        # Validate all instance types are identical
        first_type=$(echo "${required_types[0]}" | cut -d':' -f2)
        all_match=true

        echo "Validating instance types for sharing:"
        for item in "${required_types[@]}"; do
            node_type=$(echo "$item" | cut -d':' -f1)
            inst_type=$(echo "$item" | cut -d':' -f2)
            echo "  - $node_type: $inst_type"

            if [[ "$inst_type" != "$first_type" ]]; then
                all_match=false
            fi
        done
        echo ""

        if [[ "$all_match" == false ]]; then
            echo "✗ Error: All instance types must be identical when AWS_DH_SHARE_FOR_ALL_NODES=yes"
            echo ""
            echo "  Set all instance types to the same value:"
            echo "    export CONTROL_PLANE_INSTANCE_TYPE=$first_type"
            echo "    export COMPUTE_NODE_TYPE=$first_type"
            echo "    export DEFAULT_INSTANCE_TYPE=$first_type"
            exit 1
        fi

        echo "✓ All instance types match: $first_type"
        echo "  Will provision once and share across $node_type_count node types"
        echo ""
    fi
fi

# --------------------------------------------
# Provision Dedicated Hosts for each node type
# --------------------------------------------

candidate_dh_types_controlplane=""
if [[ "$AWS_DEDICATED_HOST_APPLY_TO" == *"controlPlane"* ]]; then
    if [[ -n "$CONTROL_PLANE_INSTANCE_TYPE" ]] ; then
        candidate_dh_types_controlplane="$CONTROL_PLANE_INSTANCE_TYPE"
    else
        candidate_dh_types_controlplane="$AWS_DH_CANDIDATE_TYPES"
    fi

    echo "======================================"
    echo "Provisioning DH for ControlPlane Nodes"
    echo "Candidate types: $candidate_dh_types_controlplane"
    echo "======================================"

    if [[ "$AWS_DH_SHARE_FOR_ALL_NODES" == "yes" ]]; then
        provisioned_type=$(jq  -r '.Hosts[].HostProperties.InstanceTypeaa // ""' "$provisioned_dh_file")

        if [ -n "$provisioned_type" ]; then
            # DH already exists - reuse it (validation ensures compatibility)
            echo "✓ Reusing existing DH (type: $provisioned_type) for ControlPlane nodes"
        else
            # First provisioning
            provision_dh "$candidate_dh_types_controlplane" "$provisioned_dh_file"
        fi
    else
        # Sharing disabled - always provision new
        provision_dh "$candidate_dh_types_controlplane" "$provisioned_dh_file"
    fi

    cp "$provisioned_dh_file" "${SHARED_DIR}/selected_dedicated_hosts_controlplane.json"
    echo ""
fi

candidate_dh_types_compute=""
if [[ "$AWS_DEDICATED_HOST_APPLY_TO" == *"compute"* ]]; then
    if [[ -n "$COMPUTE_NODE_TYPE" ]] ; then
        candidate_dh_types_compute="$COMPUTE_NODE_TYPE"
    else
        candidate_dh_types_compute="$AWS_DH_CANDIDATE_TYPES"
    fi

    echo "======================================"
    echo "Provisioning DH for Compute Nodes"
    echo "Candidate types: $candidate_dh_types_compute"
    echo "======================================"

    if [[ "$AWS_DH_SHARE_FOR_ALL_NODES" == "yes" ]]; then
        provisioned_type=$(jq  -r '.Hosts[].HostProperties.InstanceTypeaa // ""' "$provisioned_dh_file")

        if [ -n "$provisioned_type" ]; then
            # DH already exists - reuse it (validation ensures compatibility)
            echo "✓ Reusing existing DH (type: $provisioned_type) for Compute nodes"
        else
            # First provisioning
            provision_dh "$candidate_dh_types_compute" "$provisioned_dh_file"
        fi
    else
        # Sharing disabled - always provision new
        provision_dh "$candidate_dh_types_compute" "$provisioned_dh_file"
    fi

    cp "$provisioned_dh_file" "${SHARED_DIR}/selected_dedicated_hosts_compute.json"
    echo ""
fi

candidate_dh_types_default=""
if [[ "$AWS_DEDICATED_HOST_APPLY_TO" == *"default"* ]]; then
    candidate_dh_types_default="$AWS_DH_CANDIDATE_TYPES"

    echo "======================================"
    echo "Provisioning DH for Default Machine Pool"
    echo "Candidate types: $candidate_dh_types_default"
    echo "======================================"

    if [[ "$AWS_DH_SHARE_FOR_ALL_NODES" == "yes" ]]; then
        provisioned_type=$(jq  -r '.Hosts[].HostProperties.InstanceTypeaa // ""' "$provisioned_dh_file")

        if [ -n "$provisioned_type" ]; then
            # DH already exists - reuse it (validation ensures compatibility)
            echo "✓ Reusing existing DH (type: $provisioned_type) for Default machine pool"
        else
            # First provisioning
            provision_dh "$candidate_dh_types_default" "$provisioned_dh_file"
        fi
    else
        # Sharing disabled - always provision new
        provision_dh "$candidate_dh_types_default" "$provisioned_dh_file"
    fi

    cp "$provisioned_dh_file" "${SHARED_DIR}/selected_dedicated_hosts_default.json"
    echo ""
fi
