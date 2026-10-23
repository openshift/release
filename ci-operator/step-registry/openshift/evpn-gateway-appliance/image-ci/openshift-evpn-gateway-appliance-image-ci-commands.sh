#!/bin/bash
# Temporary probe: build the appliance bootc image from a GitHub pull request
# head, then write qcow2 and raw disks into the job artifacts.
# Remove the pull fetch before openshift/release merges this job config.
set -euo pipefail

readonly EVPN_APPLIANCE_REPO="${EVPN_APPLIANCE_REPO:-https://github.com/openshift/evpn-gateway-appliance}"
if [[ -z "${EVPN_APPLIANCE_PR:-}" ]]; then
	EVPN_APPLIANCE_PR="${PULL_NUMBER:-}"
fi
if [[ -z "${EVPN_APPLIANCE_PR}" ]]; then
	echo "image-ci: EVPN_APPLIANCE_PR or PULL_NUMBER is required" >&2
	exit 1
fi
readonly EVPN_APPLIANCE_PR
readonly WORKROOT="${WORKROOT:-/tmp/evpn-appliance-pr}"
readonly APPLIANCE_TAG="${APPLIANCE_TAG:-localhost/evpn-appliance-rhel10:ci}"
readonly IMAGE_TAG="${IMAGE_TAG:-localhost/evpn-appliance-rhel10:nested-ci}"
# image/streams.yaml bootcImageCi. The Containerfile default is registry.redhat.io.
readonly BOOTC_BASE="${BOOTC_BASE:-quay.io/centos-bootc/centos-bootc:stream10}"
readonly BIB_IMAGE="${BIB_IMAGE:-quay.io/centos-bootc/bootc-image-builder:latest}"

echo "image-ci: pull request ${EVPN_APPLIANCE_PR}"

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

# bootc-image-builder --local resolves the tag in /var/lib/containers/storage.
# This pod's store is rootless, so mount that graph root at the path the builder reads.
store="$(podman info --format '{{.Store.GraphRoot}}')"

build_disk() {
	local kind="$1"
	local filename="$2"
	local out="${WORKROOT}/output-${kind}"
	local disk dest partial
	rm -rf "${out}"
	mkdir -p "${out}"
	echo "image-ci: building ${kind} from ${APPLIANCE_TAG}"
	podman run --rm --privileged --pull=newer \
		-v "${out}:/output" \
		-v "${store}:/var/lib/containers/storage" \
		"${BIB_IMAGE}" \
		--type "${kind}" \
		--local \
		"${APPLIANCE_TAG}"
	disk="$(find "${out}" -type f -name "${filename}" -print -quit)"
	if [[ -z "${disk}" ]]; then
		echo "image-ci: ${filename} missing under ${out}" >&2
		find "${out}" -type f -print >&2 || true
		return 1
	fi
	dest="${artifacts}/${filename}.gz"
	partial="${dest}.partial"
	echo "image-ci: compressing ${disk} to ${dest}"
	rm -f "${partial}"
	if ! gzip --best -c "${disk}" > "${partial}"; then
		rm -f "${partial}"
		echo "image-ci: failed to compress ${disk}" >&2
		return 1
	fi
	mv "${partial}" "${dest}"
	echo "image-ci: saved ${dest} $(stat -c '%s' "${dest}")"
}

build_disk qcow2 disk.qcow2
build_disk raw disk.raw
