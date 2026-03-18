#!/usr/bin/env bash

set -o nounset
set -o errexit
set -o pipefail

# Get OCP version from the release image metadata.
# Must run before proxy setup: the build farm registry needs a direct connection.
export HOME="${HOME:-/tmp/home}"
export XDG_RUNTIME_DIR="${HOME}/run"
mkdir -p "${XDG_RUNTIME_DIR}"
KUBECONFIG="" oc registry login
OCP_VERSION="$(oc adm release info "${RELEASE_IMAGE_LATEST}" --output=json | jq -r '.metadata.version' | cut -d. -f1,2)"

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

# Check if the image already exists and is up-to-date
CURRENT_SHA256=""
if IMAGE_PROPS="$(openstack image show -c properties -f json "$IMAGE_NAME" 2>/dev/null)"; then
	CURRENT_SHA256="$(echo "$IMAGE_PROPS" | jq --raw-output '
		.properties["owner_specified.openstack.sha256"] //
		.properties["sha256"] //
		empty
	')"
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

	# Clean up leftover from any previous failed run
	openstack image delete "${IMAGE_NAME}-new" 2>/dev/null || true

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
	openstack image delete "${IMAGE_NAME}-old" 2>/dev/null || true
	openstack image set --name "${IMAGE_NAME}-old" "$IMAGE_NAME" 2>/dev/null || true
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
