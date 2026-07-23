#!/usr/bin/env bash

set -o nounset
set -o errexit
set -o pipefail

export OS_CLIENT_CONFIG_FILE="${SHARED_DIR}/clouds.yaml"

# For disconnected or otherwise unreachable environments, we want to
# have steps use an HTTP(S) proxy to reach the OpenStack endpoint. This proxy
# configuration file should export HTTP_PROXY, HTTPS_PROXY, and NO_PROXY
# environment variables, as well as their lowercase equivalents (note
# that libcurl doesn't recognize the uppercase variables).
if test -f "${SHARED_DIR}/proxy-conf.sh"
then
	# shellcheck disable=SC1090
	source "${SHARED_DIR}/proxy-conf.sh"
fi

# Extract stream info from the installer binary
COREOS_JSON="$(mktemp)"
openshift-install coreos print-stream-json > "$COREOS_JSON"

IMAGE_URL="$(jq --raw-output '.architectures.x86_64.artifacts.openstack.formats."qcow2.gz".disk.location' "$COREOS_JSON")"
COMPRESSED_SHA256="$(jq --raw-output '.architectures.x86_64.artifacts.openstack.formats."qcow2.gz".disk.sha256' "$COREOS_JSON")"
UNCOMPRESSED_SHA256="$(jq --raw-output '.architectures.x86_64.artifacts.openstack.formats."qcow2.gz".disk."uncompressed-sha256"' "$COREOS_JSON")"
IMAGE_VERSION="$(jq --raw-output '.architectures.x86_64.artifacts.openstack.release' "$COREOS_JSON")"
rm -f "$COREOS_JSON"

# Include the RHCOS stream version in the image name so that each
# RHCOS build gets its own immutable Glance image (e.g.
# "rhcos-422.94.202506120833-0"). The RHCOS version already encodes
# the OCP minor version (422 = 4.22, 500 = 5.0), so it is unique
# across releases. This makes each job pick their respective release.
IMAGE_NAME="${OPENSTACK_RHCOS_IMAGE_NAME}-${IMAGE_VERSION}"

echo "RHCOS version from installer: ${IMAGE_VERSION}"
echo "Target image name: ${IMAGE_NAME}"
echo "Image URL: ${IMAGE_URL}"

# Use `openstack image list` instead of `openstack image show` for all
# name-based lookups and always operate by image ID. This avoids failures
# when multiple images share the same name (e.g. after a concurrent upload
# race) and makes the script self-healing: duplicate images are cleaned up
# on the next run.

# List all images with the target name
EXISTING_IMAGES="$(openstack image list --name "$IMAGE_NAME" -f json)"
EXISTING_COUNT="$(echo "$EXISTING_IMAGES" | jq 'length')"

# If there are duplicates, clean them up (keep the newest one)
if [[ "$EXISTING_COUNT" -gt 1 ]]; then
	echo "WARNING: Found ${EXISTING_COUNT} images named '${IMAGE_NAME}'. Cleaning up duplicates..."
	DUPLICATE_IDS="$(echo "$EXISTING_IMAGES" | jq -r 'sort_by(.["Created At"]) | reverse | .[1:] | .[].ID')"
	for id in $DUPLICATE_IDS; do
		echo "  Deleting duplicate image ${id}..."
		openstack image delete "$id" 2>/dev/null || true
	done

	# Re-list after cleanup and abort if duplicates persist, to prevent
	# creating yet another image and making the problem worse.
	EXISTING_IMAGES="$(openstack image list --name "$IMAGE_NAME" -f json)"
	EXISTING_COUNT="$(echo "$EXISTING_IMAGES" | jq 'length')"
	if [[ "$EXISTING_COUNT" -gt 1 ]]; then
		echo "ERROR: Failed to clean up duplicate images named '${IMAGE_NAME}' (${EXISTING_COUNT} remaining). Aborting to prevent further accumulation."
		exit 1
	fi
fi

if [[ "$EXISTING_COUNT" -eq 1 ]]; then
	echo "RHCOS image '${IMAGE_NAME}' already exists. Skipping upload."
else
	echo "RHCOS image '${IMAGE_NAME}' not found. Uploading..."

	WORK_DIR="$(mktemp -d)"

	COMPRESSED_FILE="${WORK_DIR}/rhcos.qcow2.gz"
	UNCOMPRESSED_FILE="${WORK_DIR}/rhcos.qcow2"

	echo "Downloading RHCOS image..."
	curl --fail --location --silent --show-error --output "$COMPRESSED_FILE" "$IMAGE_URL"

	echo "Verifying compressed image checksum..."
	echo "${COMPRESSED_SHA256}  ${COMPRESSED_FILE}" | sha256sum --check --quiet

	echo "Decompressing image..."
	gunzip "$COMPRESSED_FILE"

	echo "Verifying uncompressed image checksum..."
	echo "${UNCOMPRESSED_SHA256}  ${UNCOMPRESSED_FILE}" | sha256sum --check --quiet

	echo "Uploading image to '${OS_CLOUD}' as '${IMAGE_NAME}'..."
	IMAGE_ID=$(openstack image create "${IMAGE_NAME}" \
		--container-format bare \
		--disk-format qcow2 \
		--file "$UNCOMPRESSED_FILE" \
		--private \
		--property sha256="$UNCOMPRESSED_SHA256" \
		--property rhcos_version="$IMAGE_VERSION" \
        --format value --column id)

	rm -rf "$WORK_DIR"

	echo "RHCOS image '${IMAGE_NAME}' with ID '${IMAGE_ID}' uploaded."
fi

# Patch install-config.yaml to use the pre-uploaded image
INSTALL_CONFIG="${SHARED_DIR}/install-config.yaml"
if test -f "$INSTALL_CONFIG"; then
	yq --yaml-output --in-place ".
		| .platform.openstack.clusterOSImage = \"${IMAGE_NAME}\"
	" "$INSTALL_CONFIG"
	echo "Patched install-config.yaml with clusterOSImage: ${IMAGE_NAME}"
fi

# Write the image name for downstream steps
echo "$IMAGE_NAME" > "${SHARED_DIR}/OPENSTACK_RHCOS_IMAGE_NAME"
