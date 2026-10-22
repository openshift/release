#!/bin/bash
set -euo pipefail

# Builds the Agent OVE ISO the Konflux way (agent-installer-utils iso_builder Dockerfile,
# builder base rewritten to the appliance image under test) ON the ofcir host acquired in
# the pre phase.

# Pick the openshift/agent-installer-utils branch to match the branch under test:
#   appliance master/main -> agent-installer-utils main
#   appliance release-X.Y  -> agent-installer-utils release-X.Y
if [[ "${PULL_BASE_REF:-}" == "master" || "${PULL_BASE_REF:-}" == "main" || -z "${PULL_BASE_REF:-}" ]]; then
  REF="main"
else
  REF="${PULL_BASE_REF}"
fi

ARCH="${ARCH:-x86_64}"

RELEASE_IMAGE_URL="${RELEASE_IMAGE_URL:-${RELEASE_IMAGE_LATEST:-}}"
if [[ -z "${RELEASE_IMAGE_URL}" ]]; then
  echo "ERROR: RELEASE_IMAGE_URL/RELEASE_IMAGE_LATEST not set (release:latest dependency)" >&2
  exit 1
fi

echo "Builder (appliance) image under test: ${APPLIANCE_IMAGE}"
echo "agent-installer-utils ref: ${REF} (PULL_BASE_REF=${PULL_BASE_REF:-unset})"
echo "Release image: ${RELEASE_IMAGE_URL} ; arch: ${ARCH}"

# Connect to the host acquired by ofcir-acquire
source "${SHARED_DIR}/packet-conf.sh"

scp "${SSHOPTS[@]}" "${CLUSTER_PROFILE_DIR}/pull-secret" "root@${IP}:/root/pull-secret.json"

# Run the Konflux-style build on the host.
timeout -s 9 170m ssh "${SSHOPTS[@]}" "root@${IP}" bash -s -- \
  "${REF}" "${APPLIANCE_IMAGE}" "${RELEASE_IMAGE_URL}" "${ARCH}" <<'REMOTE'
set -euo pipefail
REF="$1"; APPLIANCE_IMAGE="$2"; RELEASE_IMAGE_URL="$3"; ARCH="$4"
export PULL_SECRET_FILE="/root/pull-secret.json"

dnf -y install git make skopeo

workdir="$(mktemp -d /root/ove-build.XXXXXX)"
git clone --depth 1 --branch "${REF}" \
  https://github.com/openshift/agent-installer-utils "${workdir}/agent-installer-utils"
ISO_BUILDER_DIR="${workdir}/agent-installer-utils/tools/iso_builder"
cd "${ISO_BUILDER_DIR}"

# Rewrite the builder FROM (line 2) to the appliance image under test.
sed -i "2s|.*|FROM ${APPLIANCE_IMAGE} AS builder|" Dockerfile
echo "Rewrote Dockerfile builder stage:"
sed -n '1,2p' Dockerfile

make build-ove-iso-container \
  RELEASE_IMAGE_URL="${RELEASE_IMAGE_URL}" \
  ARCH="${ARCH}" \
  PULL_SECRET_FILE="${PULL_SECRET_FILE}"

# Extract from the built image to confirm a bootable ISO was produced. iso-from-container.sh
./hack/iso-from-container.sh
ls -lh output-iso/*.iso
echo "OVE ISO successfully built on host: $(ls output-iso/*.iso)"
REMOTE
