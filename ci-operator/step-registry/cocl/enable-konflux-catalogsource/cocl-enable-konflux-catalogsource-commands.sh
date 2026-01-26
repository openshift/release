#!/bin/bash

set -euo pipefail

# Configuration
declare CATALOG_SOURCE=${CATALOG_SOURCE_NAME}
declare FBC_INDEX_IMAGE=${MULTISTAGE_PARAM_OVERRIDE_COCL_FBC_INDEX_IMAGE}
declare COCL_OPERATOR_BRANCH=${COCL_OPERATOR_BRANCH:-main}

# Registry credentials paths
declare -r KONFLUX_REGISTRY_PATH="/var/run/vault/mirror-registry/registry_quay.json"

# Use default FBC image if not overridden
if [[ -z "$FBC_INDEX_IMAGE" ]]; then
    # Try to detect if this is a PR build by checking git log
    # Konflux embeds the revision in the commit message when syncing submodules
    echo "Checking git context to determine image tag..."
    echo "Current PWD: $(pwd)"
    echo "Git branch: $(git branch --show-current || echo 'detached')"
    echo "Latest commits:"
    git log --oneline -3 || true

    # Extract revision from commit message (Konflux format)
    REVISION=$(git log --oneline -1 | grep -oP "(?<=')[\w-]+" | head -1 || echo "")

    if [[ -n "$REVISION" ]]; then
        # Detected PR context, use PR-specific tag
        FBC_INDEX_IMAGE="quay.io/redhat-user-workloads/cocl-operator-tenant/confidential-cluster-operator-fbc:on-pr-${REVISION}"
        echo "✓ Detected PR build context"
        echo "  Revision: ${REVISION}"
        echo "  Using PR-specific FBC image: $FBC_INDEX_IMAGE"
    else
        # No revision detected, use latest (post-merge or manual testing)
        FBC_INDEX_IMAGE="quay.io/redhat-user-workloads/cocl-operator-tenant/confidential-cluster-operator-fbc:latest"
        echo "No PR revision detected, using latest FBC image: $FBC_INDEX_IMAGE"
    fi
else
    echo "Using override FBC index image: $FBC_INDEX_IMAGE"
fi

echo "CatalogSource name: $CATALOG_SOURCE"
echo "COCL operator branch: $COCL_OPERATOR_BRANCH"

run() {
    local cmd="$1"
    echo "Running: $cmd"
    eval "$cmd"
}

# Set proxy if configured
set_proxy() {
    if [[ -f "${SHARED_DIR}/proxy-conf.sh" ]]; then
        echo "Setting proxy configuration"
        source "${SHARED_DIR}/proxy-conf.sh"
    fi
}

# Update global pull secret with Konflux registry credentials
update_global_auth() {
    echo "Updating cluster global pull secret..."

    # Extract current pull secret
    oc extract secret/pull-secret -n openshift-config --confirm --to /tmp || {
        echo "ERROR: Failed to extract pull secret"
        return 1
    }

    # Read Konflux registry credentials
    if [[ ! -f "$KONFLUX_REGISTRY_PATH" ]]; then
        echo "ERROR: Konflux registry credentials not found at $KONFLUX_REGISTRY_PATH"
        return 1
    fi

    local konflux_user=$(jq -r '.user' "$KONFLUX_REGISTRY_PATH")
    local konflux_password=$(jq -r '.password' "$KONFLUX_REGISTRY_PATH")
    local konflux_auth=$(echo -n "${konflux_user}:${konflux_password}" | base64 -w 0)

    # Create new dockerconfig with Konflux registry
    local new_dockerconfig="/tmp/new-dockerconfigjson"
    jq --arg auth "$konflux_auth" \
       '.auths += {"quay.io": {"auth": $auth}, "quay.io/redhat-user-workloads": {"auth": $auth}}' \
       /tmp/.dockerconfigjson > "$new_dockerconfig" || {
        echo "ERROR: Failed to create new dockerconfig"
        return 1
    }

    # Update the secret
    oc set data secret/pull-secret -n openshift-config \
       --from-file=.dockerconfigjson="$new_dockerconfig" || {
        echo "ERROR: Failed to update pull secret"
        return 1
    }

    echo "Global pull secret updated successfully"
    echo "Waiting 10s for configuration to propagate..."
    sleep 10
}

# Apply ImageDigestMirrorSet from confidential cluster operator repo
apply_idms() {
    echo "Applying ImageDigestMirrorSet from confidential cluster operator repository..."

    local idms_url="https://raw.githubusercontent.com/confidential-clusters/operator/refs/heads/${COCL_OPERATOR_BRANCH}/.tekton/images-mirror-set.yaml"

    echo "Fetching IDMS from: $idms_url"

    if ! oc apply -f "$idms_url"; then
        echo "ERROR: Failed to apply ImageDigestMirrorSet from $idms_url"
        return 1
    fi

    echo "✓ ImageDigestMirrorSet applied successfully"
    return 0
}

# Wait for Konflux image to be available
wait_for_image() {
    local image="$1"
    local timeout=1500  # 25 minutes (same as kueue-operator)
    local counter=0

    echo "========================================="
    echo "Waiting for Konflux image to be available"
    echo "Image: $image"
    echo "Timeout: ${timeout}s (25 minutes)"
    echo "========================================="

    while [ $counter -lt $timeout ]; do
        # Try to inspect the image using skopeo
        if skopeo inspect --no-tags "docker://$image" &>/dev/null 2>&1; then
            echo ""
            echo "✓ Image is available: $image"
            echo ""
            return 0
        fi

        # Image not ready yet
        if [ $((counter % 60)) -eq 0 ]; then
            echo "  Image not ready yet... (${counter}s / ${timeout}s)"
        fi

        sleep 30
        counter=$((counter + 30))
    done

    # Timeout reached
    echo ""
    echo "========================================="
    echo "ERROR: Image not available after ${timeout}s"
    echo "Image: $image"
    echo "========================================="
    echo ""
    echo "This typically means:"
    echo "  1. Konflux build has not completed yet"
    echo "  2. Konflux build failed"
    echo "  3. Image tag is incorrect"
    echo ""
    echo "Please check:"
    echo "  - Konflux build status in the downstream PR"
    echo "  - Image tag matches Konflux build output"
    echo ""
    return 1
}

# Ensure openshift-marketplace namespace exists
check_marketplace() {
    if oc get namespace openshift-marketplace &>/dev/null; then
        echo "openshift-marketplace namespace exists"
        return 0
    fi

    echo "Creating openshift-marketplace namespace..."
    cat <<EOF | oc apply -f -
apiVersion: v1
kind: Namespace
metadata:
  name: openshift-marketplace
  labels:
    security.openshift.io/scc.podSecurityLabelSync: "false"
    pod-security.kubernetes.io/enforce: baseline
    pod-security.kubernetes.io/audit: baseline
    pod-security.kubernetes.io/warn: baseline
EOF
}

# Create CatalogSource
create_catalog_source() {
    echo "Creating CatalogSource: $CATALOG_SOURCE"

    cat <<EOF | oc apply -f -
apiVersion: operators.coreos.com/v1alpha1
kind: CatalogSource
metadata:
  name: $CATALOG_SOURCE
  namespace: openshift-marketplace
spec:
  displayName: COCL Operator Dev Preview (Konflux)
  image: $FBC_INDEX_IMAGE
  publisher: Confidential Clusters Team
  sourceType: grpc
  updateStrategy:
    registryPoll:
      interval: 15m
EOF

    # Wait for CatalogSource to be READY
    echo "Waiting for CatalogSource to become READY..."
    local timeout=600
    local counter=0
    local status=""

    while [ $counter -lt $timeout ]; do
        status=$(oc -n openshift-marketplace get catalogsource "$CATALOG_SOURCE" \
                 -o=jsonpath='{.status.connectionState.lastObservedState}' 2>/dev/null || echo "")

        if [[ "$status" == "READY" ]]; then
            echo "✓ CatalogSource $CATALOG_SOURCE is READY"
            return 0
        fi

        echo "  Status: $status - waiting... (${counter}s / ${timeout}s)"
        sleep 20
        counter=$((counter + 20))
    done

    # Debugging if failed
    echo "ERROR: CatalogSource failed to become READY after ${timeout}s"
    echo ""
    echo "=== CatalogSource Details ==="
    oc -n openshift-marketplace get catalogsource "$CATALOG_SOURCE" -o yaml || true
    echo ""
    echo "=== CatalogSource Pods ==="
    oc -n openshift-marketplace get pods -l "olm.catalogSource=$CATALOG_SOURCE" -o wide || true
    echo ""
    echo "=== Pod Logs ==="
    oc -n openshift-marketplace logs -l "olm.catalogSource=$CATALOG_SOURCE" --tail=100 || true
    echo ""
    echo "=== Pod Describe ==="
    oc -n openshift-marketplace describe pods -l "olm.catalogSource=$CATALOG_SOURCE" || true
    echo ""
    echo "=== MachineConfigPool Status ==="
    oc get mcp || true
    echo ""
    echo "=== Node Status ==="
    oc get nodes || true

    return 1
}

# Main execution
main() {
    echo "========================================="
    echo "Enabling Konflux catalog for confidential cluster operator"
    echo "========================================="

    set_proxy

    echo "Cluster info:"
    oc whoami
    oc version -o yaml | head -20

    echo ""
    echo "Step 1: Update global authentication"
    update_global_auth || {
        echo "ERROR: Failed to update global authentication"
        exit 1
    }

    echo ""
    echo "Step 2: Apply ImageDigestMirrorSet"
    apply_idms || {
        echo "ERROR: Failed to apply IDMS"
        exit 1
    }

    echo ""
    echo "Step 3: Ensure marketplace namespace exists"
    check_marketplace || {
        echo "ERROR: Failed to ensure marketplace namespace"
        exit 1
    }

    echo ""
    echo "Step 3.5: Verify FBC image availability"
    wait_for_image "$FBC_INDEX_IMAGE" || {
        echo "ERROR: Konflux FBC image not available"
        echo "Image: $FBC_INDEX_IMAGE"
        exit 1
    }

    echo ""
    echo "Step 4: Create CatalogSource"
    create_catalog_source || {
        echo "ERROR: Failed to create CatalogSource"
        exit 1
    }

    # Save IDMS for hypershift guest cluster configuration (if needed)
    if oc get imagedigestmirrorset &>/dev/null; then
        echo ""
        echo "Saving IDMS configuration for potential hypershift usage..."
        oc get imagedigestmirrorset -oyaml > /tmp/mgmt_idms.yaml || true
        if command -v yq-go &>/dev/null; then
            yq-go r /tmp/mgmt_idms.yaml 'items[*].spec.imageDigestMirrors' - 2>/dev/null | \
                sed '/---*/d' > "$SHARED_DIR"/mgmt_idms.yaml || true
        fi
    fi

    echo ""
    echo "========================================="
    echo "✓ Konflux catalog setup completed successfully!"
    echo "CatalogSource '$CATALOG_SOURCE' is ready in openshift-marketplace"
    echo ""
    echo "Next steps:"
    echo "  - Use 'install-operators' step with OPERATORS env"
    echo "  - Reference source: '$CATALOG_SOURCE'"
    echo "  - Package name: 'confidential-cluster-operator'"
    echo "  - Channel: 'alpha'"
    echo "========================================="
}

main
