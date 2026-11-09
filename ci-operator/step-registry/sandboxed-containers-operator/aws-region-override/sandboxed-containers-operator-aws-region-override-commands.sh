#!/bin/bash

set -o nounset
set -o errexit
set -o pipefail

# Assisted-by: Cursor AI
echo "=========================================="
echo "Sandboxed Containers Operator - AWS Region Override Step"
echo "=========================================="


# Validate that we have the necessary variables
if [[ -z ${LEASED_RESOURCE:-} ]]; then
    echo "ERROR: LEASED_RESOURCE is undefined"
    exit 1
fi

CONFIG="${SHARED_DIR}/install-config.yaml"
if [[ ! -f "${CONFIG}" ]]; then
    echo "ERROR: install-config.yaml not found at ${CONFIG}"
    echo "This step must run after the base IPI configuration step"
    exit 1
fi

echo "Original leased region: ${LEASED_RESOURCE}"

# Determine the target region
TARGET_AWS_REGION=""

# Priority 1: Explicit AWS_REGION_OVERRIDE environment variable
if [[ ! -z ${AWS_REGION_OVERRIDE:-} ]]; then
    TARGET_AWS_REGION="${AWS_REGION_OVERRIDE}"
    echo "Using explicit region override: ${TARGET_AWS_REGION}"

    # Optional: Validate against allowed regions list
    if [[ ! -z ${AWS_ALLOWED_REGIONS:-} ]]; then
        IFS=" " read -r -a ALLOWED_REGIONS <<< "$AWS_ALLOWED_REGIONS"
        region_allowed=false
        for allowed_region in "${ALLOWED_REGIONS[@]}"; do
            if [[ "$allowed_region" == "$TARGET_AWS_REGION" ]]; then
                region_allowed=true
                break
            fi
        done

        if [[ "$region_allowed" == "false" ]]; then
            echo "ERROR: Specified region ${TARGET_AWS_REGION} is not in allowed regions list: ${AWS_ALLOWED_REGIONS}"
            exit 1
        fi
    fi

# Priority 2: Region from allowed list (random selection if multiple)
elif [[ ! -z ${AWS_ALLOWED_REGIONS:-} ]]; then
    IFS=" " read -r -a ALLOWED_REGIONS <<< "$AWS_ALLOWED_REGIONS"

    # Check if leased region is in allowed list
    region_allowed=false
    for allowed_region in "${ALLOWED_REGIONS[@]}"; do
        if [[ "$allowed_region" == "$LEASED_RESOURCE" ]]; then
            region_allowed=true
            TARGET_AWS_REGION="$LEASED_RESOURCE"
            echo "Leased region ${LEASED_RESOURCE} is in allowed regions list"
            break
        fi
    done

    # If leased region not allowed, select random from allowed list
    if [[ "$region_allowed" == "false" ]]; then
        TARGET_AWS_REGION="${ALLOWED_REGIONS[$RANDOM % ${#ALLOWED_REGIONS[@]}]}"
        echo "=========================================="
        echo "Leased region ${LEASED_RESOURCE} is not in allowed regions list"
        echo "Selecting random region from allowed list: ${TARGET_AWS_REGION}"
        echo "Allowed regions: ${AWS_ALLOWED_REGIONS}"
        echo "=========================================="
    fi

# Priority 3: Use leased region (no override needed)
else
    echo "No region override specified, using leased region: ${LEASED_RESOURCE}"
    exit 0
fi

# Only proceed if we have a target region different from leased resource
if [[ -z "$TARGET_AWS_REGION" ]] || [[ "$TARGET_AWS_REGION" == "$LEASED_RESOURCE" ]]; then
    echo "No region change needed"
    exit 0
fi

echo "=========================================="
echo "Overriding AWS region from ${LEASED_RESOURCE} to ${TARGET_AWS_REGION}"
echo "This ensures sandboxed containers operator tests run in the specified region"
echo "=========================================="

# Backup original config
cp "${CONFIG}" "${CONFIG}.backup"

# Method 1: Use yq to modify the region (preferred if yq is available)
if command -v yq &> /dev/null; then
    echo "Using yq to modify install-config.yaml"
    yq eval ".platform.aws.region = \"${TARGET_AWS_REGION}\"" -i "${CONFIG}"

    # Update zones if they exist and are region-specific
    current_zones=$(yq eval '.platform.aws.zones // []' "${CONFIG}")
    if [[ "$current_zones" != "[]" && "$current_zones" != "null" ]]; then
        echo "Updating availability zones for new region..."
        # Clear existing zones - let the installer pick appropriate zones for the new region
        yq eval 'del(.platform.aws.zones)' -i "${CONFIG}"
        echo "Cleared specific zones - installer will select appropriate zones for ${TARGET_AWS_REGION}"
    fi

    # Update compute zones if they exist
    yq eval 'del(.compute[].platform.aws.zones)' -i "${CONFIG}" 2>/dev/null || true
    # Update control plane zones if they exist
    yq eval 'del(.controlPlane.platform.aws.zones)' -i "${CONFIG}" 2>/dev/null || true

else
    echo "Using sed to modify install-config.yaml (yq not available)"
    # Fallback method using sed
    sed -i "s/region: ${LEASED_RESOURCE}/region: ${TARGET_AWS_REGION}/g" "${CONFIG}"

    # Remove any hardcoded zones that might be region-specific
    sed -i '/zones:/,/^[[:space:]]*[^[:space:]-]/{ /zones:/d; /^[[:space:]]*-[[:space:]]*[a-z0-9-]*[a-z]$/d; }' "${CONFIG}"
fi

# Validate the change
echo "=========================================="
echo "Validating configuration changes..."
echo "=========================================="

if command -v yq &> /dev/null; then
    new_region=$(yq eval '.platform.aws.region' "${CONFIG}")
    if [[ "$new_region" == "$TARGET_AWS_REGION" ]]; then
        echo "✓ Region successfully updated to: ${new_region}"
    else
        echo "✗ Region update failed. Expected: ${TARGET_AWS_REGION}, Got: ${new_region}"
        exit 1
    fi
else
    if grep -q "region: ${TARGET_AWS_REGION}" "${CONFIG}"; then
        echo "✓ Region successfully updated to: ${TARGET_AWS_REGION}"
    else
        echo "✗ Region update failed"
        exit 1
    fi
fi

# Show the diff for debugging
echo "=========================================="
echo "Configuration changes (diff):"
echo "=========================================="
diff "${CONFIG}.backup" "${CONFIG}" || true

# Export the target region for use by subsequent steps
echo "${TARGET_AWS_REGION}" > "${SHARED_DIR}/aws-region"
echo "Region information saved to ${SHARED_DIR}/aws-region"

# Update AWS credentials to use the new region if needed
if [[ ! -z ${AWS_SHARED_CREDENTIALS_FILE:-} ]] && [[ -f "${AWS_SHARED_CREDENTIALS_FILE}" ]]; then
    export AWS_DEFAULT_REGION="${TARGET_AWS_REGION}"
    echo "Set AWS_DEFAULT_REGION to ${TARGET_AWS_REGION}"
fi

echo "=========================================="
echo "Sandboxed Containers Operator - AWS Region Override completed successfully"
echo "Original region: ${LEASED_RESOURCE}"
echo "Target region: ${TARGET_AWS_REGION}"
echo "Ready for sandboxed containers operator testing in ${TARGET_AWS_REGION}"
echo "=========================================="
