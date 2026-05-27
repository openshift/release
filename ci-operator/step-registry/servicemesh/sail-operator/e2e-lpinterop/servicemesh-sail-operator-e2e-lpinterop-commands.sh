#!/bin/bash

# ==============================================================================
# E2E Limited Preview Interoperability Test Script
#
# This script runs end-to-end interoperability tests for the Sail Operator
# in Limited Preview mode on OpenShift clusters.
#
# It performs the following steps:
# 1. Sets up the Kubernetes environment and switches to the default project.
# 2. Configures the operator namespace from the OPERATOR_NAMESPACE variable
#    (used instead of NAMESPACE to avoid conflicts with global environment).
# 3. Executes the e2e.ocp test suite using the configured test environment.
# 4. Collects test artifacts and saves them as JUnit XML reports.
# 5. Preserves the original exit code from the test execution for proper
#    CI failure reporting, even if artifact collection succeeds.
#
# Required Environment Variables:
#   - SHARED_DIR: Directory containing the kubeconfig file.
#   - OPERATOR_NAMESPACE: The namespace where the operator is installed.
#   - ARTIFACT_DIR: The local directory to store test artifacts.
#
# Notes:
#   - Uses OPERATOR_NAMESPACE instead of NAMESPACE to avoid conflicts with
#     global pipeline variables used during the post phase.
#   - JUnit report files must start with 'junit' prefix for CI recognition.
# ==============================================================================

set -euxo pipefail; shopt -s inherit_errexit

if [ "${MAP_TESTS}" = "true" ]; then
    eval "$(
        curl -fsSL \
            https://raw.githubusercontent.com/RedHatQE/OpenShift-LP-QE--Tools/refs/heads/main/libs/bash/ci-operator/interop/common/ExitTrap--PostProcessPrep.sh    )"; trap '
        LP_IO__ET_PPP__NEW_TS_NAME="${DR__RP__CR_COMP_NAME}--%s" \
            ExitTrap--PostProcessPrep junit--servicemesh-operator__e2e-lpinterop.xml
    ' EXIT
fi
# Function to pre-pull container images on all OCP nodes
# Usage: prepull_image_on_nodes <image-name>
# Example: prepull_image_on_nodes "ztunnel"
prepull_image_on_nodes() {
    local IMAGE_NAME="$1"
    local CSV_PATTERN="servicemeshoperator3"

    # Validate input
    if [ -z "$IMAGE_NAME" ]; then
        echo -e "Error: Image name is required"
        echo "Usage: prepull_image_on_nodes <image-name>"
        return 1
    fi

    # Auto-detect CSV
    echo -e "Auto-detecting latest servicemeshoperator3 CSV..."
    oc get csv
    local CSV_NAME
    CSV_NAME=$(oc get csv -o json | jq -r --arg pattern "$CSV_PATTERN" '
      .items[] |
      select(.metadata.name | startswith($pattern)) |
      {name: .metadata.name, version: (.metadata.name | capture($pattern + "\\.v(?<v>.*)").v // "0")}
    ' | jq -rs 'sort_by(.version | split(".") | map(tonumber)) | last | .name')

    if [ -z "$CSV_NAME" ] || [ "$CSV_NAME" = "null" ]; then
        echo -e "Error: Could not auto-detect CSV matching pattern '${CSV_PATTERN}'"
        echo "Available CSVs:"
        oc get csv -o jsonpath='{range .items[*]}{.metadata.name}{"\n"}{end}' | grep "$CSV_PATTERN" || echo "None found"
        return 1
    fi
    echo -e "Detected CSV: ${CSV_NAME}"

    echo -e "=== Pre-pulling ${IMAGE_NAME} image on all OCP nodes ==="

    # Step 1: Extract the latest patch version for each minor version from CSV
    echo -e "\nStep 1: Extracting latest ${IMAGE_NAME} images for each minor version from CSV ${CSV_NAME}..."

    local TARGET_IMAGES
    TARGET_IMAGES=$(oc get csv "$CSV_NAME" -o json | jq -r --arg img "$IMAGE_NAME" '
      [.spec.relatedImages[] |
      select(.name | contains($img)) |
      {
        name: .name,
        image: .image,
        version: (.name | capture("images_v(?<v>.*?)_" + $img).v // "0"),
        minor: (.name | capture("images_v(?<maj>\\d+)_(?<min>\\d+)_.*?_" + $img) | "\(.maj).\(.min)")
      }] |
      group_by(.minor) |
      map(sort_by(.version | split("_") | map(tonumber)) | last) |
      sort_by(.minor | split(".") | map(tonumber)) |
      reverse |
      .[] |
      "\(.minor): \(.image)"
    ')

    if [ -z "$TARGET_IMAGES" ]; then
        echo -e "Error: Could not find ${IMAGE_NAME} images in CSV"
        echo "Available images with '${IMAGE_NAME}' in name:"
        oc get csv "$CSV_NAME" -o json | jq -r --arg img "$IMAGE_NAME" '.spec.relatedImages[] | select(.name | contains($img)) | "\(.name): \(.image)"'
        return 1
    fi

    echo -e "Found latest ${IMAGE_NAME} images for each minor version:"
    echo "$TARGET_IMAGES" | while IFS= read -r line; do
        echo -e "  $line"
    done

    # Step 2: Get all nodes
    echo -e "\nStep 2: Getting all OCP nodes..."
    local NODES
    NODES=$(oc get nodes -o jsonpath='{.items[*].metadata.name}')

    if [ -z "$NODES" ]; then
        echo -e "Error: No nodes found"
        return 1
    fi

    local NODE_COUNT
    NODE_COUNT=$(echo $NODES | wc -w)
    echo -e "Found $NODE_COUNT nodes"

    # Step 3: Pre-pull all images on each node
    echo -e "\nStep 3: Pre-pulling images on all nodes..."

    local TOTAL_PULLS=0
    local SUCCESSFUL_PULLS=0
    local FAILED_PULLS=0
    local FAILED_DETAILS=()

    # Extract just the image URLs (remove the "minor: " prefix)
    local IMAGE_URLS
    IMAGE_URLS=$(echo "$TARGET_IMAGES" | cut -d' ' -f2)

    for NODE in $NODES; do
        echo -e "\nProcessing node: $NODE"

        while IFS= read -r IMAGE_URL; do
            [ -z "$IMAGE_URL" ] && continue

            local IMAGE_VERSION
            IMAGE_VERSION=$(echo "$TARGET_IMAGES" | grep "$IMAGE_URL" | cut -d':' -f1)

            echo -e "  Pulling ${IMAGE_VERSION}..."
            TOTAL_PULLS=$((TOTAL_PULLS + 1))

            local OUTPUT
            local PULL_EXIT_CODE

            # Use oc debug to access the node and pull the image
            set +e
            OUTPUT=$(oc debug node/$NODE -- chroot /host sh -c "crictl pull \"$IMAGE_URL\"" 2>&1)
            PULL_EXIT_CODE=$?
            set -e
            echo "$OUTPUT" | grep -E "(Image is up to date|Image is updated|Downloaded|Pulling|error|Error)" || true

            # Check if the pull was successful
            local GREP_RESULT
            set +e
            echo "$OUTPUT" | grep -qE "(Image is up to date|Image is updated|Downloaded|Pulling)"
            GREP_RESULT=$?
            set -e

            if [ $GREP_RESULT -eq 0 ] || [ $PULL_EXIT_CODE -eq 0 ]; then
                echo -e "  ✓ Successfully pulled ${IMAGE_VERSION} on node $NODE"
                SUCCESSFUL_PULLS=$((SUCCESSFUL_PULLS + 1))
            else
                echo -e "  ✗ Failed to pull ${IMAGE_VERSION} on node $NODE"
                FAILED_PULLS=$((FAILED_PULLS + 1))
                FAILED_DETAILS+=("$NODE: $IMAGE_VERSION")
            fi
        done <<< "$IMAGE_URLS"
    done

    # Summary
    echo -e "\n=== Summary ==="
    echo -e "Total nodes: $NODE_COUNT"
    echo -e "Total pull attempts: $TOTAL_PULLS"
    echo -e "Successful pulls: $SUCCESSFUL_PULLS"

    if [ $FAILED_PULLS -gt 0 ]; then
        echo -e "Failed pulls: $FAILED_PULLS"
        echo -e "Failed details:"
        for DETAIL in "${FAILED_DETAILS[@]}"; do
            echo -e "  - $DETAIL"
        done
        return 1
    else
        echo -e "All nodes successfully pulled all ${IMAGE_NAME} images!"
        return 0
    fi
}

# login for interop
if [ -s "${KUBECONFIG}" ]; then
    oc whoami
else #login for ROSA & Hypershift platforms
    (set +x; eval "$(cat "${SHARED_DIR}/api.login")")
fi

export XDG_CACHE_HOME="/tmp/cache"
# We need to switch to the default project, since the container doesn't have permission to see the project in kubeconfig context
oc project default

# we cannot use NAMESPACE env in servicemesh-sail-operator-e2e-lpinterop-ref.yaml since it overrides some global NAMESPACE env 
# which is used during post phase of step (so the pipeline tried to update secret in openshift operator namespace which resulted in error).
# Due to that, OPERATOR_NAMESPACE env is used in the step ref definition
export NAMESPACE=${OPERATOR_NAMESPACE}

typeset -i ret_code=0

mkdir ./test_artifacts
ARTIFACTS="$(pwd)/test_artifacts"
export ARTIFACTS

# workaround for a node network instability during test execution, prepull images which must be on each node
prepull_image_on_nodes "ztunnel"
prepull_image_on_nodes "cni"

FIPS_CLUSTER=false
# If fips cluster, patch network config to be able to run ambient tests
if [[ $(oc get machineconfigs | grep fips) ]]; then
    echo "Patching network config to be able to run ambient tests on fips cluster"
    oc patch networks.operator.openshift.io cluster --type=merge -p '{"spec":{"defaultNetwork":{"ovnKubernetesConfig":{"gatewayConfig":{"routingViaHost": true}}}}}'
    FIPS_CLUSTER=true
fi
export FIPS_CLUSTER

#execute test, do not terminate when there is some failure since we want to archive junit files
make test.e2e.ocp || ret_code=$?

# report saved status code from make, in case test.e2e.ocp failed with panic in some test case (and junit doesn't contain error)
exit "${ret_code}"
