#!/bin/bash

set -e
set -u
set -o pipefail

# Skip step if no MCPs are configured
if [ -z "$MCO_CONF_DAY1_ENABLE_OCL_MCPS" ]; then
  echo "MCO_CONF_DAY1_ENABLE_OCL_MCPS is empty. Skipping day1 OCL configuration."
  # Create empty mcps file to signal the check step that this was intentionally skipped
  touch "${SHARED_DIR}/mco-day1-ocl-mcps"
  exit 0
fi

# Create temporary directory in /tmp
TMP_DIR="/tmp/tmp-osimage-build"
mkdir -p "$TMP_DIR"

CONTAINERFILE="$TMP_DIR/Containerfile"
PULL_SECRET="$TMP_DIR/pull-secret"
MCOQE_AUTH_FILE="$TMP_DIR/mcoqe-auth.json"

# Set up pull-secret with CI registry credentials
echo "Setting up pull-secret with CI registry credentials..."
cp ${CLUSTER_PROFILE_DIR}/pull-secret "$PULL_SECRET"
oc registry login --to "$PULL_SECRET"

# Get the CoreOS base image from the release
echo "Getting CoreOS base image from release ${RELEASE_IMAGE_LATEST}..."
BASE_IMAGE=$(oc adm release info --registry-config "$PULL_SECRET" "${RELEASE_IMAGE_LATEST}" --image-for="rhel-coreos")
echo "Base image: $BASE_IMAGE"

# Create authentication file for mcoqe (for podman push)
echo "Setting up authentication for quay.io/mcoqe..."
echo -n '{"auths": {"quay.io": {"auth": "'"$(base64 -w 0 /var/run/vault/mcoqe-robot-account/auth)"'"}}}' > "$MCOQE_AUTH_FILE"

# Create the Containerfile
echo "Creating Containerfile..."
cat > "$CONTAINERFILE" << EOF
FROM $BASE_IMAGE

LABEL maintainer="mco-qe-team" quay.expires-after=$MCO_CONF_DAY1_ENABLE_OCL_IMAGE_EXPIRATION

$MCO_CONF_DAY1_ENABLE_OCL_CONTAINERFILE_CONTENT
EOF

echo "Containerfile contents:"
cat "$CONTAINERFILE"

# Build the custom osImage
IMAGE_NAME="quay.io/mcoqe/layering:$MCO_CONF_DAY1_ENABLE_OCL_TAG"
echo ""
echo "Building custom osImage..."
podman build --authfile "$PULL_SECRET" -t "$IMAGE_NAME" -f "$CONTAINERFILE" "$TMP_DIR"

# Push the image to quay.io/mcoqe/layering and capture digest
echo ""
echo "Pushing image to $IMAGE_NAME..."
DIGEST_FILE="$TMP_DIR/digest"
podman push --authfile "$MCOQE_AUTH_FILE" --digestfile "$DIGEST_FILE" "$IMAGE_NAME"

# Get the image digest from the digest file
echo ""
echo "Getting image digest..."
IMAGE_DIGEST=$(cat "$DIGEST_FILE")
IMAGE_WITH_DIGEST="quay.io/mcoqe/layering@$IMAGE_DIGEST"

echo ""
echo "============================================"
echo "Custom osImage built and pushed successfully!"
echo "Image: $IMAGE_NAME"
echo "Digest: $IMAGE_DIGEST"
echo "Full reference: $IMAGE_WITH_DIGEST"
echo "============================================"

# Create secret manifest with mcoqe credentials
echo ""
echo "Creating layering-push-secret manifest..."
SECRET_MANIFEST="${SHARED_DIR}/manifest_layering-push-secret.yaml"

cat > "$SECRET_MANIFEST" << EOF
apiVersion: v1
kind: Secret
metadata:
  name: layering-push-secret
  namespace: openshift-machine-config-operator
type: kubernetes.io/dockerconfigjson
data:
  .dockerconfigjson: $(echo -n '{"auths": {"quay.io": {"auth": "'"$(base64 -w 0 /var/run/vault/mcoqe-robot-account/auth)"'"}}}' | base64 -w 0)
EOF

echo "Created secret manifest at $SECRET_MANIFEST"

# Create MachineOSConfig manifest for each pool
for mcp in $MCO_CONF_DAY1_ENABLE_OCL_MCPS; do
  echo ""
  echo "Creating MachineOSConfig manifest for pool: $mcp"

  MOSC_MANIFEST="${SHARED_DIR}/manifest_machineosconfig-${mcp}.yaml"

  cat > "$MOSC_MANIFEST" << EOF
apiVersion: machineconfiguration.openshift.io/v1
kind: MachineOSConfig
metadata:
  name: ${mcp}
  annotations:
    machineconfiguration.openshift.io/pre-built-image: "${IMAGE_WITH_DIGEST}"
spec:
  machineConfigPool:
    name: ${mcp}
  imageBuilder:
    imageBuilderType: Job
  renderedImagePushSecret:
    name: layering-push-secret
  renderedImagePushSpec: "${MCO_CONF_DAY1_ENABLE_OCL_RENDERED_IMAGE_PUSH_SPEC}"
  containerFile:
  - content: |-
      LABEL maintainer="mco-qe-team" quay.expires-after=${MCO_CONF_DAY1_ENABLE_OCL_IMAGE_EXPIRATION}
      ${MCO_CONF_DAY1_ENABLE_OCL_CONTAINERFILE_CONTENT}
EOF

  echo "Created MachineOSConfig manifest at $MOSC_MANIFEST"
done

echo ""
echo "============================================"
echo "All manifests created successfully!"
echo "Secret: ${SHARED_DIR}/manifest_layering-push-secret.yaml"
for mcp in $MCO_CONF_DAY1_ENABLE_OCL_MCPS; do
  echo "MachineOSConfig ($mcp): ${SHARED_DIR}/manifest_machineosconfig-${mcp}.yaml"
done
echo "============================================"

# Save OCL deployment info for check step
echo "$IMAGE_WITH_DIGEST" > "${SHARED_DIR}/mco-day1-ocl-image-reference"
echo "$MCO_CONF_DAY1_ENABLE_OCL_MCPS" > "${SHARED_DIR}/mco-day1-ocl-mcps"
echo "$MCO_CONF_DAY1_ENABLE_OCL_RENDERED_IMAGE_PUSH_SPEC" > "${SHARED_DIR}/mco-day1-ocl-rendered-image-push-spec"
echo "Saved OCL deployment info to ${SHARED_DIR} for verification"

# Cleanup
rm -rf "$TMP_DIR"
