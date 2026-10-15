#!/bin/bash
# Temporary probe: build the appliance bootc image and the nested CI derivative
# from a GitHub pull request head. Remove the pull fetch before openshift/release
# merges this job config.
set -euo pipefail

readonly EVPN_APPLIANCE_REPO="${EVPN_APPLIANCE_REPO:-https://github.com/openshift/evpn-gateway-appliance}"
readonly EVPN_APPLIANCE_PR="${EVPN_APPLIANCE_PR:-16}"
readonly WORKROOT="${WORKROOT:-/tmp/evpn-appliance-pr}"
readonly APPLIANCE_TAG="${APPLIANCE_TAG:-localhost/evpn-appliance-rhel10:ci}"
readonly IMAGE_TAG="${IMAGE_TAG:-localhost/evpn-appliance-rhel10:nested-ci}"
# image/streams.yaml bootcImageCi. The Containerfile default is registry.redhat.io.
readonly BOOTC_BASE="${BOOTC_BASE:-quay.io/centos-bootc/centos-bootc:stream10}"

rm -rf "${WORKROOT}"
mkdir -p "${WORKROOT}"
# nested-podman is UBI with curl and tar, and it has no git. The step runs as uid 1000, so dnf cannot install git.
repo_slug="${EVPN_APPLIANCE_REPO#https://github.com/}"
sha="$(curl -fsSL "https://api.github.com/repos/${repo_slug}/commits/refs/pull/${EVPN_APPLIANCE_PR}/head" | sed -n 's/^  "sha": "\([0-9a-f]\{40\}\)".*/\1/p' | head -n 1)"
if [[ -z "${sha}" ]]; then
	echo "image-ci: could not read pull request head sha" >&2
	exit 1
fi
echo "image-ci: HEAD ${sha}"
echo "image-ci: fetching ${EVPN_APPLIANCE_REPO} archive ${sha}"
archive="$(mktemp)"
curl -fsSL -o "${archive}" -L "${EVPN_APPLIANCE_REPO}/archive/${sha}.tar.gz"
tar -xzf "${archive}" -C "${WORKROOT}" --strip-components=1
rm -f "${archive}"
echo "image-ci: BOOTC_BASE ${BOOTC_BASE}"

pull_secret="/var/run/ci-pull-credentials/.dockerconfigjson"
if [[ ! -f "${pull_secret}" ]]; then
	echo "image-ci: no pull secret file found; nested CI payload cache cannot pull registry.redhat.io" >&2
	exit 1
fi
echo "image-ci: using pull secret at ${pull_secret}"

cd "${WORKROOT}"
echo "image-ci: building product image from image/rhel10/Containerfile"
podman build \
	-t "${APPLIANCE_TAG}" \
	-f image/rhel10/Containerfile \
	--build-arg "BOOTC_BASE=${BOOTC_BASE}" \
	image

echo "image-ci: building nested CI image from image/Containerfile.nested-ci"
export REGISTRY_AUTH_FILE="${pull_secret}"
podman build \
	-t "${IMAGE_TAG}" \
	-f image/Containerfile.nested-ci \
	--pull=never \
	--build-arg "APPLIANCE_IMAGE=${APPLIANCE_TAG}" \
	--secret "id=registry-auth,src=${pull_secret}" \
	image

echo "image-ci: build succeeded ${IMAGE_TAG}"

artifacts="${ARTIFACT_DIR:-/tmp/artifacts}"
mkdir -p "${artifacts}"
if ! command -v gzip >/dev/null; then
	echo "image-ci: gzip is required to save images" >&2
	exit 1
fi
save_image() {
	local tag="$1"
	local name="$2"
	local dest="${artifacts}/${name}-${sha}.tar.gz"
	local partial="${dest}.partial"
	echo "image-ci: saving ${tag} to ${dest}"
	rm -f "${partial}"
	if ! podman save "${tag}" | gzip -1 > "${partial}"; then
		rm -f "${partial}"
		echo "image-ci: failed to save ${tag}" >&2
		return 1
	fi
	mv "${partial}" "${dest}"
	echo "image-ci: saved ${dest} $(stat -c '%s' "${dest}")"
}
# Product first. bootc-image-builder consumes this archive. A later failure keeps it.
save_image "${APPLIANCE_TAG}" "evpn-appliance-rhel10"
save_image "${IMAGE_TAG}" "evpn-appliance-rhel10-nested-ci"
