#!/bin/bash
set -euo pipefail

readonly EVPN_APPLIANCE_REPO="${EVPN_APPLIANCE_REPO:-https://github.com/openshift/evpn-gateway-appliance}"
readonly EVPN_APPLIANCE_PR="${EVPN_APPLIANCE_PR:-6}"
readonly WORKROOT="${WORKROOT:-/tmp/evpn-appliance-pr}"
readonly IMAGE_TAG="${IMAGE_TAG:-localhost/evpn-appliance-rhel10:ci-probe}"
readonly BOOTC_BASE="${BOOTC_BASE:-quay.io/centos-bootc/centos-bootc:stream10}"
readonly FRR_IMAGE="${FRR_IMAGE:-registry.ci.openshift.org/ocp/4.22:metallb-frr}"
readonly NODE_EXPORTER_IMAGE="${NODE_EXPORTER_IMAGE:-registry.ci.openshift.org/ocp/4.22:prometheus-node-exporter}"
readonly BIB_IMAGE="${BIB_IMAGE:-quay.io/centos-bootc/bootc-image-builder:latest}"
pull_secret=""
for candidate in /var/run/registry-pull-credentials/.dockerconfigjson /etc/pull-secret/.dockerconfigjson "${HOME:-}/.docker/config.json"; do
	if [[ -f "${candidate}" ]]; then
		pull_secret="${candidate}"
		echo "image-ci: using pull secret at ${candidate}"
		break
	fi
done

echo "image-ci: fetching ${EVPN_APPLIANCE_REPO} pull request ${EVPN_APPLIANCE_PR}"
if [[ -z "${pull_secret}" ]]; then
	echo "image-ci: required registry pull secret not found" >&2
	exit 1
fi
export REGISTRY_AUTH_FILE="${pull_secret}"

rm -rf "${WORKROOT}"
mkdir -p "${WORKROOT}"
repo_slug="${EVPN_APPLIANCE_REPO#https://github.com/}"
sha="$(curl -fsSL -H 'Accept: application/vnd.github.sha' "https://api.github.com/repos/${repo_slug}/commits/refs/pull/${EVPN_APPLIANCE_PR}/head")"
if [[ ! "${sha}" =~ ^[0-9a-f]{40}$ ]]; then
	echo "image-ci: could not read a full pull request head sha" >&2
	exit 1
fi
echo "image-ci: HEAD ${sha}"
echo "image-ci: fetching immutable archive ${sha}"
archive="$(mktemp)"
curl -fsSL -o "${archive}" -L "${EVPN_APPLIANCE_REPO}/archive/${sha}.tar.gz"
tar -xzf "${archive}" -C "${WORKROOT}" --strip-components=1
rm -f "${archive}"

cd "${WORKROOT}/image/rhel10"
echo "image-ci: building appliance image ${IMAGE_TAG}"
podman build \
	-t "${IMAGE_TAG}" \
	-f Containerfile \
	--build-arg "BOOTC_BASE=${BOOTC_BASE}" \
	--build-arg "FRR_IMAGE=${FRR_IMAGE}" \
	--build-arg "NODE_EXPORTER_IMAGE=${NODE_EXPORTER_IMAGE}" \
	--secret "id=dockerconfig,src=${pull_secret}" \
	.

cd "${WORKROOT}"
bash image/tools/smoke-nested.sh "${IMAGE_TAG}"

artifacts="${ARTIFACT_DIR:-/tmp/artifacts}"
mkdir -p "${artifacts}"
if ! command -v gzip >/dev/null; then
	echo "image-ci: gzip is required to save disks" >&2
	exit 1
fi

store="$(podman info --format '{{.Store.GraphRoot}}')"

build_disk() {
	local kind="$1"
	local filename="$2"
	local out="${WORKROOT}/output-${kind}"
	local disk dest partial
	rm -rf "${out}"
	mkdir -p "${out}"
	echo "image-ci: building ${kind} from ${IMAGE_TAG}"
	podman run --rm --privileged --pull=newer \
		-v "${out}:/output" \
		-v "${store}:/var/lib/containers/storage" \
		"${BIB_IMAGE}" \
		--type "${kind}" \
		--local \
		"${IMAGE_TAG}"
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
