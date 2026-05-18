#!/usr/bin/env bash

set -o nounset
set -o errexit
set -o pipefail

# Get OCP version from the installer binary itself.
# This ensures the Glance image name matches the RHCOS content that the
# installer embeds, which is important for upgrade jobs where the installer
# version can differ from the release under test.
OCP_VERSION="$(openshift-install version 2>/dev/null | sed -n 's/^release image\s\+.*:\([0-9]\+\.[0-9]\+\).*/\1/p')"
if [[ ! "${OCP_VERSION}" =~ ^[0-9]+\.[0-9]+$ ]]; then
	echo "ERROR: Failed to extract OCP version from openshift-install:" >&2
	openshift-install version >&2
	exit 1
fi

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

IMAGE_NAME="${OPENSTACK_RHCOS_IMAGE_NAME}-${OCP_VERSION}"

echo "RHCOS version from installer: ${IMAGE_VERSION}"
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

# Check if the (single remaining) image is up-to-date
CURRENT_SHA256=""
CURRENT_ID=""
if [[ "$EXISTING_COUNT" -ge 1 ]]; then
	CURRENT_ID="$(echo "$EXISTING_IMAGES" | jq -r 'sort_by(.["Created At"]) | reverse | .[0].ID')"
	if IMAGE_PROPS="$(openstack image show -c properties -f json "$CURRENT_ID" 2>/dev/null)"; then
		CURRENT_SHA256="$(echo "$IMAGE_PROPS" | jq --raw-output '
			.properties["owner_specified.openstack.sha256"] //
			.properties["sha256"] //
			empty
		')"
	fi
fi

if [[ "$CURRENT_SHA256" == "$UNCOMPRESSED_SHA256" ]]; then
	echo "RHCOS image '${IMAGE_NAME}' already at the expected version (${IMAGE_VERSION}). Skipping upload."
else
	echo "RHCOS image '${IMAGE_NAME}' needs to be uploaded (current sha256: '${CURRENT_SHA256}', expected: '${UNCOMPRESSED_SHA256}')"

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

	# Clean up leftover from any previous failed run (by ID to handle duplicates)
	for id in $(openstack image list --name "${IMAGE_NAME}-new" -f value -c ID 2>/dev/null); do
		openstack image delete "$id" 2>/dev/null || true
	done

	echo "Uploading image to '${OS_CLOUD}' as '${IMAGE_NAME}-new'..."
	NEW_IMAGE_ID="$(openstack image create "${IMAGE_NAME}-new" \
		--container-format bare \
		--disk-format qcow2 \
		--file "$UNCOMPRESSED_FILE" \
		--private \
		--property sha256="$UNCOMPRESSED_SHA256" \
		--property rhcos_version="$IMAGE_VERSION" \
		--format value --column id)"

	echo "Replacing old '${IMAGE_NAME}' image with new one..."
	# Delete old images by ID
	for id in $(openstack image list --name "${IMAGE_NAME}-old" -f value -c ID 2>/dev/null); do
		openstack image delete "$id" 2>/dev/null || true
	done
	# Rename current image to -old (by ID, not name)
	if [[ -n "$CURRENT_ID" ]]; then
		openstack image set --name "${IMAGE_NAME}-old" "$CURRENT_ID" 2>/dev/null || true
	fi
	# Promote the new image (already using ID)
	openstack image set --name "$IMAGE_NAME" "$NEW_IMAGE_ID"

	rm -rf "$WORK_DIR"

	echo "RHCOS image '${IMAGE_NAME}' updated to version ${IMAGE_VERSION}."
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
