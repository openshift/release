#!/bin/bash
set -o nounset
set -o errexit
set -o pipefail

# TODO remove this step once Arc is available in more regions.

if [[ -z ${LEASED_RESOURCE:-} ]]; then
    echo "LEASED_RESOURCE is undefined"
    exit 1
fi

# If an Azure region is provided, check to see if that region matches the lease.
if [[ ! -z ${AZURE_REGION:-} ]]; then    
    if [[ "$LEASED_RESOURCE" != "$AZURE_REGION" ]]; then
        echo Intended AZURE_REGION $AZURE_REGION does not match LEASED_RESOURCE $LEASED_RESOURCE   
        exit 0 
    fi
fi

# If not, check to see if there is an allowed region list to check
if [[ ! -z ${AZURE_ARC_REGIONS:-} ]]; then    
    IFS=" " read -r -a AZURE_ARC_REGIONS <<< "$AZURE_ARC_REGIONS"   

    for ALLOWED_REGION in "${AZURE_ARC_REGIONS[@]}"; do        
        if [ $ALLOWED_REGION == $LEASED_RESOURCE ]; then
            echo "Leased region $LEASED_RESOURCE is enabled for ARC. Allowing use of that lease."
            AZURE_REGION=$LEASED_RESOURCE
            break
        fi        
    done

    if [[ -z ${AZURE_REGION:-} ]]; then
        # Select a region at random since the LEASED_RESOURCE is not allowed
        AZURE_REGION=${AZURE_ARC_REGIONS[$RANDOM % ${#AZURE_ARC_REGIONS[@]}]}
        echo "================================================"
        echo "Azure Arc-enabled Kubernetes clusters are not" 
        echo "available in ${LEASED_RESOURCE}."
        echo "Patching region to ${AZURE_REGION}..."
        echo "================================================"
    fi
fi

if [[ -z ${AZURE_REGION:-} ]]; then
    # Nothing to do.
    exit 0
fi

CONFIG="${SHARED_DIR}/install-config.yaml"
COMPUTE_NODE_TYPE="Standard_D4s_v3"
cat >> "${CONFIG}" << EOF
baseDomain: ci.azure.devcluster.openshift.com
compute:
- name: worker
  platform:
    azure:
      type: ${COMPUTE_NODE_TYPE}
platform:
  azure:
    baseDomainResourceGroupName: os4-common
    region: ${AZURE_REGION}
EOF