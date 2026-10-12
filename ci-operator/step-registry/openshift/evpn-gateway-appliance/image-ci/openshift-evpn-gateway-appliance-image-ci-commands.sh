#!/bin/bash
# Temporary probe: build appliance bootc image from a GitHub pull request head.
# Remove the pull/6 fetch before openshift/release merges this job config.
set -euo pipefail

readonly EVPN_APPLIANCE_REPO="${EVPN_APPLIANCE_REPO:-https://github.com/openshift/evpn-gateway-appliance}"
readonly EVPN_APPLIANCE_PR="${EVPN_APPLIANCE_PR:-6}"
readonly WORKROOT="${WORKROOT:-/tmp/evpn-appliance-pr}"
readonly IMAGE_TAG="${IMAGE_TAG:-localhost/evpn-appliance-rhel10:ci-probe}"
# image/streams.yaml bootcImageCi. The Containerfile default is registry.redhat.io.
readonly BOOTC_BASE="${BOOTC_BASE:-quay.io/centos-bootc/centos-bootc:stream10}"
# openshift/frr and openshift/node_exporter promote these tags to ocp/4.22.
# The Containerfile pins registry.redhat.io, which this pod cannot pull.
readonly FRR_METRICS_IMAGE="${FRR_METRICS_IMAGE:-registry.ci.openshift.org/ocp/4.22:metallb-frr}"
readonly NODE_EXPORTER_IMAGE="${NODE_EXPORTER_IMAGE:-registry.ci.openshift.org/ocp/4.22:prometheus-node-exporter}"

echo "image-ci: fetching ${EVPN_APPLIANCE_REPO} pull request ${EVPN_APPLIANCE_PR}"
rm -rf "${WORKROOT}"
mkdir -p "${WORKROOT}"
# nested-podman is UBI with curl and tar, and it has no git. The step runs as uid 1000, so dnf cannot install git.
repo_slug="${EVPN_APPLIANCE_REPO#https://github.com/}"
archive="$(mktemp)"
curl -fsSL -o "${archive}" -L "${EVPN_APPLIANCE_REPO}/archive/refs/pull/${EVPN_APPLIANCE_PR}/head.tar.gz"
tar -xzf "${archive}" -C "${WORKROOT}" --strip-components=1
rm -f "${archive}"
sha="$(curl -fsSL "https://api.github.com/repos/${repo_slug}/commits/refs/pull/${EVPN_APPLIANCE_PR}/head" | sed -n 's/^  "sha": "\([0-9a-f]\{40\}\)".*/\1/p' | head -n 1)"
if [[ -z "${sha}" ]]; then
	echo "image-ci: could not read pull request head sha" >&2
	exit 1
fi
echo "image-ci: HEAD ${sha}"
echo "image-ci: BOOTC_BASE ${BOOTC_BASE}"
echo "image-ci: FRR_METRICS_IMAGE ${FRR_METRICS_IMAGE}"
echo "image-ci: NODE_EXPORTER_IMAGE ${NODE_EXPORTER_IMAGE}"

pull_secret=""
for candidate in /var/run/registry-pull-credentials/.dockerconfigjson /etc/pull-secret/.dockerconfigjson "${HOME}/.docker/config.json"; do
	if [[ -f "${candidate}" ]]; then
		pull_secret="${candidate}"
		echo "image-ci: using pull secret at ${candidate}"
		break
	fi
done
if [[ -z "${pull_secret}" ]]; then
	echo "image-ci: no pull secret file found; build will probe registry auth failures"
fi

cd "${WORKROOT}/image/rhel10"
build_args=(
	-t "${IMAGE_TAG}"
	-f Containerfile
	--build-arg "BOOTC_BASE=${BOOTC_BASE}"
	--build-arg "FRR_METRICS_IMAGE=${FRR_METRICS_IMAGE}"
	--build-arg "NODE_EXPORTER_IMAGE=${NODE_EXPORTER_IMAGE}"
	.
)
if [[ -n "${pull_secret}" ]]; then
	export REGISTRY_AUTH_FILE="${pull_secret}"
	podman build "${build_args[@]}" --secret "id=dockerconfig,src=${pull_secret}"
else
	podman build "${build_args[@]}"
fi

echo "image-ci: build succeeded ${IMAGE_TAG}"
