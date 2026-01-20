#!/bin/bash

set -o nounset
set -o errexit
set -o pipefail

# save the exit code for junit xml file generated in step gather-must-gather
# post check steps after manifest generation, exit code 100 if failed,
# save to install-pre-config-status.txt
EXIT_CODE=100
trap 'if [[ "$?" == 0 ]]; then EXIT_CODE=0; fi; echo "${EXIT_CODE}" > "${SHARED_DIR}/install-pre-config-status.txt"' EXIT TERM

echo "=========================================="
echo "OCPBUGS-69923: Verify Manifest Zone Consistency"
echo "=========================================="
echo ""

# Check required tools
if ! command -v yq >/dev/null 2>&1; then
    echo "Error: yq tool is required"
    exit 1
fi

# Installation directory is typically /tmp/installer
INSTALL_DIR="/tmp/installer"
if [ ! -d "$INSTALL_DIR" ]; then
    echo "Error: Installation directory does not exist: $INSTALL_DIR"
    echo "       Manifests should be generated before this step"
    exit 1
fi

echo "Installation directory: $INSTALL_DIR"
echo ""

# Check if manifest files exist
CAPI_FILES=$(find "$INSTALL_DIR"/openshift -name "*cluster-api*master*.yaml" -type f 2>/dev/null | sort || true)
MAPI_FILES=$(find "$INSTALL_DIR"/openshift -name "*machine-api*master*.yaml" -type f 2>/dev/null | sort || true)

if [ -z "$CAPI_FILES" ]; then
    echo "❌ Error: CAPI manifest files not found"
    echo "   Please ensure manifests have been generated: openshift-install create manifests"
    exit 1
fi

if [ -z "$MAPI_FILES" ]; then
    echo "❌ Error: MAPI manifest files not found"
    echo "   Please ensure manifests have been generated: openshift-install create manifests"
    exit 1
fi

echo "Found CAPI and MAPI manifest files"
echo ""

# Get CAPI zones
echo "=== CAPI Machine Zones ==="
capi_zones=()
capi_index=0
for file in $CAPI_FILES; do
    zone=$(yq eval '.spec.providerSpec.value.placement.availabilityZone' "$file" 2>/dev/null || echo "")
    if [ -n "$zone" ] && [ "$zone" != "null" ] && [ "$zone" != "" ]; then
        capi_zones+=("$zone")
        echo "  master-$capi_index ($(basename "$file")): $zone"
        capi_index=$((capi_index + 1))
    fi
done

if [ ${#capi_zones[@]} -eq 0 ]; then
    echo "  ⚠️  Warning: No CAPI zone information found"
    echo "    Attempted path: .spec.providerSpec.value.placement.availabilityZone"
    exit 1
fi

echo ""

# Get MAPI zones
echo "=== MAPI Machine Zones ==="
mapi_zones=()

# MAPI files are ControlPlaneMachineSet, need to extract zones from failureDomains
for file in $MAPI_FILES; do
    kind=$(yq eval '.kind' "$file" 2>/dev/null || echo "")
    if [ "$kind" = "ControlPlaneMachineSet" ]; then
        zones=$(yq eval '.spec.template.machines_v1beta1_machine_openshift_io.failureDomains.aws[].placement.availabilityZone' "$file" 2>/dev/null || echo "")
        if [ -n "$zones" ]; then
            master_count=${#capi_zones[@]}
            if [ $master_count -eq 0 ]; then
                master_count=3  # Default 3 masters
            fi
            
            mapi_index=0
            for zone in $zones; do
                if [ "$zone" != "null" ] && [ -n "$zone" ] && [ "$zone" != "" ]; then
                    if [ $mapi_index -lt $master_count ]; then
                        mapi_zones+=("$zone")
                        echo "  master-$mapi_index (from $(basename "$file")): $zone"
                        mapi_index=$((mapi_index + 1))
                    else
                        break
                    fi
                fi
            done
        fi
    else
        # If it's a direct Machine object
        zone=$(yq eval '.spec.providerSpec.value.placement.availabilityZone' "$file" 2>/dev/null || echo "")
        if [ -n "$zone" ] && [ "$zone" != "null" ] && [ "$zone" != "" ]; then
            mapi_zones+=("$zone")
            echo "  master-${#mapi_zones[@]} ($(basename "$file")): $zone"
        fi
    fi
done

if [ ${#mapi_zones[@]} -eq 0 ]; then
    echo "  ⚠️  Warning: No MAPI zone information found"
    echo "    Attempted path: .spec.template.machines_v1beta1_machine_openshift_io.failureDomains.aws[].placement.availabilityZone"
    exit 1
fi

echo ""

# Compare
echo "=========================================="
echo "Consistency Check"
echo "=========================================="

if [ ${#capi_zones[@]} -ne ${#mapi_zones[@]} ]; then
    echo "⚠️  Warning: CAPI and MAPI have different number of machines"
    echo "   CAPI: ${#capi_zones[@]} machines"
    echo "   MAPI: ${#mapi_zones[@]} machines"
    echo ""
fi

all_match=true
max_count=${#capi_zones[@]}
if [ ${#mapi_zones[@]} -gt $max_count ]; then
    max_count=${#mapi_zones[@]}
fi

ret=0
for i in $(seq 0 $((max_count - 1))); do
    capi_zone="${capi_zones[$i]:-N/A}"
    mapi_zone="${mapi_zones[$i]:-N/A}"
    
    if [ "$capi_zone" = "$mapi_zone" ] && [ "$capi_zone" != "N/A" ]; then
        echo "✓ Match: master-$i - Zone: $capi_zone"
    else
        echo "❌ Mismatch: master-$i - CAPI: $capi_zone, MAPI: $mapi_zone"
        all_match=false
        ret=$((ret + 1))
    fi
done

echo ""

if [ "$all_match" = true ]; then
    echo "✅ Manifest verification PASSED: All machines have consistent zone allocation!"
    echo ""
    echo "Manifest verification: PASS ✓"
    exit 0
else
    echo "❌ Manifest verification FAILED: Zone allocation inconsistency detected!"
    echo ""
    echo "Manifest verification: FAIL ✗"
    echo ""
    echo "This indicates that the fix for OCPBUGS-69923 may not be effective."
    exit $ret
fi
