#!/bin/bash
# Purpose: Mirror specific KubeVirt and utility images to the cluster's internal image registry.

set -eux

# 1. Extract KUBEVIRT_TAG dynamically from virt-operator deployment
function get_kubevirt_tag () {
    echo "Extracting KUBEVIRT_TAG from virt-operator deployment..."

    # Get the image of virt-operator deployment
    VIRT_OPERATOR_IMAGE=$(oc get deployment -n openshift-cnv virt-operator -o json | jq -r '.spec.template.spec.containers[0].image')
    echo "virt-operator image: $VIRT_OPERATOR_IMAGE"

    # Get the image info and extract the upstream-version label
    UPSTREAM_VERSION=$(skopeo inspect --tls-verify=false "docker://${VIRT_OPERATOR_IMAGE}" | jq -r '.Labels["upstream-version"]')
    echo "upstream-version label: $UPSTREAM_VERSION"

    # Extract version
    VERSION=$(echo "$UPSTREAM_VERSION" | cut -d'-' -f1)

    # If VERSION could not be extracted, fall back to KUBEVIRT_TAG env var
    if [ -z "$VERSION" ] || [ "$VERSION" == "null" ]; then
        echo "WARNING: Could not extract version from upstream-version label"
        if [ -n "${KUBEVIRT_TAG:-}" ]; then
            echo "Falling back to KUBEVIRT_TAG from environment: $KUBEVIRT_TAG"
        else
            echo "ERROR: KUBEVIRT_TAG environment variable is also not set"
            exit 1
        fi
    else
        # Prefix with 'v'
        KUBEVIRT_TAG="v${VERSION}"
        echo "Extracted KUBEVIRT_TAG: $KUBEVIRT_TAG"
    fi

    export KUBEVIRT_TAG
}

# 2. Define the List of Images to Mirror (called after KUBEVIRT_TAG is set)
function define_images_to_mirror () {
    IMAGES_TO_MIRROR=(
        "registry.redhat.io/container-native-virtualization/virt-operator-rhel9@sha256:73777220e2d7463a68a966c92a7aee4f903270d00fe297b4d9accfed39d54393"
        "quay.io/kubevirt/alpine-container-disk-demo:${KUBEVIRT_TAG}"
        "quay.io/kubevirt/alpine-with-test-tooling-container-disk:${KUBEVIRT_TAG}"
        "quay.io/kubevirt/cirros-container-disk-demo:${KUBEVIRT_TAG}"
        "quay.io/kubevirt/cirros-custom-container-disk-demo:${KUBEVIRT_TAG}"
        "quay.io/kubevirt/fedora-realtime-container-disk:${KUBEVIRT_TAG}"
        "quay.io/kubevirt/fedora-with-test-tooling-container-disk:${KUBEVIRT_TAG}"
        "quay.io/kubevirt/virtio-container-disk:${KUBEVIRT_TAG}"
        "quay.io/kubevirt/alpine-ext-kernel-boot-demo:${KUBEVIRT_TAG}"
        "quay.io/kubevirt/example-hook-sidecar:${KUBEVIRT_TAG}"
        "quay.io/kubevirt/example-cloudinit-hook-sidecar:${KUBEVIRT_TAG}"
        "quay.io/kubevirt/example-disk-mutation-hook-sidecar:${KUBEVIRT_TAG}"
        "quay.io/kubevirt/sidecar-shim:${KUBEVIRT_TAG}"
        "quay.io/kubevirt/network-passt-binding:${KUBEVIRT_TAG}"
        "quay.io/kubevirt/disks-images-provider:${KUBEVIRT_TAG}"
        "quay.io/kubevirt/vm-killer:${KUBEVIRT_TAG}"
        "quay.io/kubevirt/winrmcli:${KUBEVIRT_TAG}"
        "ghcr.io/astral-sh/uv:latest"
    )
}

# 3. Proxy Configuration
function set_proxy () {
    if test -s "${SHARED_DIR}/proxy-conf.sh" ; then
        echo "setting the proxy"
        echo "source ${SHARED_DIR}/proxy-conf.sh"
        source "${SHARED_DIR}/proxy-conf.sh"
        export no_proxy=brew.registry.redhat.io,registry.stage.redhat.io,registry.redhat.io,registry.ci.openshift.org,quay.io,s3.us-east-1.amazonaws.com
        export NO_PROXY=brew.registry.redhat.io,registry.stage.redhat.io,registry.redhat.io,registry.ci.openshift.org,quay.io,s3.us-east-1.amazonaws.com
    else
        echo "no proxy setting found in ${SHARED_DIR}."
    fi
}

# 4. Setup Internal Image Registry
function setup_internal_registry () {
    echo "Setting up internal image registry..."

    # Create PVC for the image registry (100GiB, RWO, filesystem mode)
    echo "Creating PVC for image registry..."
    cat <<EOF | oc apply -f -
apiVersion: v1
kind: PersistentVolumeClaim
metadata:
  name: registry-pvc
  namespace: openshift-image-registry
spec:
  accessModes:
    - ReadWriteOnce
  volumeMode: Filesystem
  resources:
    requests:
      storage: 100Gi
  storageClassName: ocs-storagecluster-ceph-rbd
EOF

    # Wait for PVC to be bound
    echo "Waiting for PVC to be bound..."
    if ! oc wait --for=jsonpath='{.status.phase}'=Bound pvc/registry-pvc -n openshift-image-registry --timeout=300s; then
        echo "ERROR: Timed out waiting for PVC to be bound"
        echo "--- PVC YAML ---"
        oc get pvc/registry-pvc -n openshift-image-registry -o yaml || true
        echo "--- PVC Events ---"
        oc get events -n openshift-image-registry --field-selector involvedObject.name=registry-pvc || true
        exit 1
    fi

    # Patch the image registry to use the PVC and set management state
    echo "Patching image registry configuration..."
    oc patch configs.imageregistry.operator.openshift.io/cluster --type=merge --patch '
{
  "spec": {
    "managementState": "Managed",
    "rolloutStrategy": "Recreate",
    "storage": {
      "pvc": {
        "claim": "registry-pvc"
      }
    }
  }
}'

    # Expose the default route
    echo "Exposing image registry route..."
    oc patch configs.imageregistry.operator.openshift.io/cluster --patch '{"spec":{"defaultRoute":true}}' --type=merge

    # Wait for the registry deployment to be created and ready
    echo "Waiting for image registry deployment to be created..."
    TIMEOUT=300
    INTERVAL=10
    ELAPSED=0
    while ! oc get deployment/image-registry -n openshift-image-registry &>/dev/null; do
        if [ $ELAPSED -ge $TIMEOUT ]; then
            echo "ERROR: Timed out waiting for deployment/image-registry to be created"
            echo "--- Image Registry Config ---"
            oc get configs.imageregistry.operator.openshift.io/cluster -o yaml || true
            echo "--- Pods in openshift-image-registry namespace ---"
            oc get pods -n openshift-image-registry -o wide || true
            oc describe pods -n openshift-image-registry || true
            exit 1
        fi
        echo "Deployment not yet created, waiting ${INTERVAL}s... (${ELAPSED}s/${TIMEOUT}s)"
        sleep $INTERVAL
        ELAPSED=$((ELAPSED + INTERVAL))
    done
    echo "Deployment created, waiting for it to be available..."

    if ! oc wait --for=condition=Available deployment/image-registry -n openshift-image-registry --timeout=600s; then
        echo "ERROR: Timed out waiting for deployment/image-registry to be available"
        echo "--- Image Registry Config ---"
        oc get configs.imageregistry.operator.openshift.io/cluster -o yaml || true
        echo "--- Deployment YAML ---"
        oc get deployment/image-registry -n openshift-image-registry -o yaml || true
        echo "--- Pods in openshift-image-registry namespace ---"
        oc get pods -n openshift-image-registry -o wide || true
        oc describe pods -n openshift-image-registry || true
        exit 1
    fi

    # Get the registry host
    echo "Getting registry route..."
    REGISTRY_HOST=$(oc get route default-route -n openshift-image-registry --template='{{ .spec.host }}')
    echo "Registry URL: $REGISTRY_HOST"

    # Add the registry to insecure registries list (for TLS certificate issues)
    echo "Adding registry to insecure registries list..."
    oc patch image.config.openshift.io/cluster --type=merge --patch "{
      \"spec\": {
        \"registrySources\": {
          \"insecureRegistries\": [
            \"${REGISTRY_HOST}\"
          ]
        }
      }
    }"

    # Wait for the Machine Config to start rolling out
    echo "Waiting for Machine Config changes to propagate..."
    echo "Note: This may take several minutes as nodes are updated"
    sleep 30

    # Wait for all MachineConfigPools to be updated
    echo "Waiting for MachineConfigPools to be updated..."
    oc wait mcp --all --for=condition=Updated=True --timeout=30m || {
        echo "WARNING: MachineConfigPool update timed out or failed"
        echo "--- MachineConfigPool status ---"
        oc get mcp
        echo "Continuing anyway, but image pulls may fail until nodes are updated"
    }

    export REGISTRY_HOST
}

# 5. Create required namespaces in the cluster for image storage
function create_image_namespaces () {
    echo "Creating namespaces for image storage..."

    # Extract unique namespaces from images (first path component after domain)
    declare -A NAMESPACES
    for SRC_IMG in "${IMAGES_TO_MIRROR[@]}"; do
        # Extract namespace (first path component after domain)
        # e.g., quay.io/kubevirt/image:tag -> kubevirt
        NS=$(echo "$SRC_IMG" | cut -d/ -f2)
        NAMESPACES["$NS"]=1
    done

    # Create each namespace if it doesn't exist
    for NS in "${!NAMESPACES[@]}"; do
        echo "Creating namespace: $NS"
        oc create namespace "$NS" --dry-run=client -o yaml | oc apply -f -
    done
}

# 6. Enable image pulls for all service accounts
function enable_image_pulls () {
    echo "Enabling image pulls for all service accounts..."

    # Extract unique namespaces from images
    declare -A NAMESPACES
    for SRC_IMG in "${IMAGES_TO_MIRROR[@]}"; do
        NS=$(echo "$SRC_IMG" | cut -d/ -f2)
        NAMESPACES["$NS"]=1
    done

    # Grant image pull permissions to allow any authenticated user/service account to pull
    for NS in "${!NAMESPACES[@]}"; do
        echo "Enabling image pulls for namespace: $NS"
        # Allow anonymous pulls
        oc policy add-role-to-user registry-viewer system:anonymous -n "$NS"
        # Allow any authenticated user to pull (includes all service accounts)
        oc policy add-role-to-user registry-viewer system:authenticated -n "$NS"
        # Grant system:image-puller to all service accounts cluster-wide for this namespace
        oc policy add-role-to-group system:image-puller system:serviceaccounts -n "$NS"
    done
}

# 7. Main Mirroring Logic
function mirror_images () {
    echo "Configuring credentials for internal registry..."

    work_dir="/tmp"
    # Setting runtime dir for skopeo auth
    export XDG_RUNTIME_DIR=$work_dir
    export REGISTRY_AUTH_FILE="$XDG_RUNTIME_DIR/containers/auth.json"

    mkdir -p "$XDG_RUNTIME_DIR/containers"

    echo "Setting up service account for registry authentication..."

    # Create a dedicated service account for image mirroring
    SA_NAME="image-mirror-sa"
    SA_NS="openshift-image-registry"
    oc create serviceaccount "$SA_NAME" -n "$SA_NS" --dry-run=client -o yaml | oc apply -f -

    AUTH_USER="system:serviceaccount:${SA_NS}:${SA_NAME}"

    # Grant system:image-builder cluster role to allow pushing images to the registry
    echo "Granting system:image-builder cluster role to $AUTH_USER"
    oc adm policy add-cluster-role-to-user system:image-builder "$AUTH_USER"

    # Grant registry-editor role to the SA for all target namespaces
    declare -A NAMESPACES
    for SRC_IMG in "${IMAGES_TO_MIRROR[@]}"; do
        NS=$(echo "$SRC_IMG" | cut -d/ -f2)
        NAMESPACES["$NS"]=1
    done
    for NS in "${!NAMESPACES[@]}"; do
        echo "Granting registry-editor role to $AUTH_USER in namespace: $NS"
        oc policy add-role-to-user registry-editor "$AUTH_USER" -n "$NS"
    done

    # Extract cluster pull secret for source registry authentication (e.g., registry.redhat.io)
    echo "Extracting cluster pull secret for source registry authentication..."
    SRC_AUTH_FILE="$XDG_RUNTIME_DIR/containers/cluster-pull-secret.json"
    oc get secret/pull-secret -n openshift-config -o jsonpath='{.data.\.dockerconfigjson}' | base64 -d > "$SRC_AUTH_FILE"
    echo "Cluster pull secret extracted to $SRC_AUTH_FILE"

    # Create token and auth file for destination registry authentication
    echo "Creating token and auth file for destination registry authentication..."
    set +x
    TOKEN=$(oc create token "$SA_NAME" -n "$SA_NS" --duration=2h)
    # Create auth file in Docker config format
    AUTH_STRING=$(echo -n "${SA_NAME}:${TOKEN}" | base64 -w0)
    cat > "$REGISTRY_AUTH_FILE" <<EOF
{
  "auths": {
    "${REGISTRY_HOST}": {
      "auth": "${AUTH_STRING}"
    }
  }
}
EOF
    set -x
    echo "Destination auth file created at $REGISTRY_AUTH_FILE"

    echo "Starting Image Mirroring to internal registry..."

    for SRC_IMG in "${IMAGES_TO_MIRROR[@]}"; do
        # Strip the domain from the source to create the destination path
        # e.g., quay.io/kubevirt/image:tag -> kubevirt/image:tag
        IMG_PATH=$(echo "$SRC_IMG" | cut -d/ -f2-)

        # Handle digest references - replace @sha256:xxx with a tag
        # Digests cannot be used as destination references, so convert to tag
        if [[ "$IMG_PATH" == *"@sha256:"* ]]; then
            # Extract the image name (before @) and digest
            IMG_NAME=$(echo "$IMG_PATH" | cut -d'@' -f1)
            DIGEST=$(echo "$IMG_PATH" | cut -d'@' -f2)
            # Use first 12 chars of digest as tag (like docker short ID)
            SHORT_DIGEST=$(echo "$DIGEST" | sed 's/sha256://' | cut -c1-12)
            DEST_PATH="${IMG_NAME}:${SHORT_DIGEST}"
            echo "Note: Converting digest reference to tag for destination"
        else
            DEST_PATH="$IMG_PATH"
        fi

        # Construct destination URL using internal registry
        DEST_IMG="docker://${REGISTRY_HOST}/${DEST_PATH}"

        echo "------------------------------------------------"
        echo "Source:      ${SRC_IMG}"
        echo "Destination: ${DEST_IMG}"

        # Perform the copy
        skopeo copy --all \
            --remove-signatures \
            --src-tls-verify=false \
            --dest-tls-verify=false \
            --src-authfile "$SRC_AUTH_FILE" \
            --dest-authfile "$REGISTRY_AUTH_FILE" \
            --retry-times 3 \
            "docker://${SRC_IMG}" "${DEST_IMG}"
        COPY_RC=$?

        if [ $COPY_RC -eq 0 ]; then
            echo "✓ Successfully mirrored: ${IMG_PATH}"
        else
            echo "✗ Failed to mirror: ${SRC_IMG}"
        fi
    done

    echo "================================================"
    echo "Image mirroring complete!"
    echo "Internal registry host: ${REGISTRY_HOST}"
    echo "================================================"
}

# --- Main ---
set_proxy
get_kubevirt_tag
define_images_to_mirror
setup_internal_registry
create_image_namespaces
mirror_images
enable_image_pulls
