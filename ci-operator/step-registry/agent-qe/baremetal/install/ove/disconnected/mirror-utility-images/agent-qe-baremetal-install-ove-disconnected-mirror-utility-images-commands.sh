#!/bin/bash
# Purpose: Mirror specific KubeVirt and utility images to the internal disconnected registry.

set -ux


# 1. Define the List of Images to Mirror
declare -a IMAGES_TO_MIRROR=(
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
    "quay.io/kubevirt/vm-killer:${KUBEVIRT_TAG}"
    "quay.io/kubevirt/winrmcli:${KUBEVIRT_TAG}"
    "ghcr.io/astral-sh/uv:latest"
    "quay.io/orenc/container-native-virtualization-ocp-virt-validation-checkup-rhel9:latest"
)

# 2. Proxy Configuration
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

# 3. Main Mirroring Logic
function mirror_images () {
    echo "Configuring credentials..."
    
    # Credential file paths
    mirror_registry_cred_file="/var/run/vault/mirror-registry/registry_creds"
    
    # Ensure credential file exists before trying to read
    if [ ! -f "$mirror_registry_cred_file" ]; then
        echo "Error: Credential file $mirror_registry_cred_file not found."
        echo "Ensure you are running this in the correct CI environment or Vault context."
        exit 1
    fi

    mirror_registry_user=`cat $mirror_registry_cred_file|cut -d: -f1`
    mirror_registry_password=`cat $mirror_registry_cred_file|cut -d: -f2`

    work_dir="/tmp"
    # Setting runtime dir for Podman/Skopeo auth
    export XDG_RUNTIME_DIR=$work_dir
    export REGISTRY_AUTH_FILE="$XDG_RUNTIME_DIR/containers/auth.json"
    
    mkdir -p "$XDG_RUNTIME_DIR/containers"

    echo "Logging into registries..."
    # Login to internal mirror
    skopeo login ${MIRROR_REGISTRY_HOST} -u ${mirror_registry_user} -p ${mirror_registry_password} --tls-verify=false
    
    echo "Starting Image Mirroring..."

    for SRC_IMG in "${IMAGES_TO_MIRROR[@]}"; do
        # Strip the domain from the source to create the destination path
        # e.g., quay.io/kubevirt/image:tag -> kubevirt/image:tag
        IMG_PATH=$(echo "$SRC_IMG" | cut -d/ -f2-)
        
        # Construct destination URL
        DEST_IMG="docker://${MIRROR_REGISTRY_HOST}/${IMG_PATH}"
        
        echo "------------------------------------------------"
        echo "Source:      ${SRC_IMG}"
        echo "Destination: ${DEST_IMG}"

        # Perform the copy
        skopeo copy --all \
            --remove-signatures \
            --src-tls-verify=false \
            --dest-tls-verify=false \
            --retry-times 3 \
            "docker://${SRC_IMG}" "${DEST_IMG}"

        if [ $? -eq 0 ]; then
            echo "✓ Successfully mirrored: ${IMG_PATH}"
        else
            echo "x Failed to mirror: ${SRC_IMG}"
        fi
    done
}

# --- Main ---
set_proxy
mirror_images