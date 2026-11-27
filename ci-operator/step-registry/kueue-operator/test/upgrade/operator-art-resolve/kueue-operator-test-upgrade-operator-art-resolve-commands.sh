#!/usr/bin/env bash

set -e
set -u
set -o pipefail

# Resolve the in-channel (z-stream) operator upgrade pair from the ART FBC.
#
# kueue-operator-enable-catalogsource-art already resolved the ART FBC floating
# tag to a pinned digest and wrote it to ${SHARED_DIR}/kueue_index_image. This
# step extracts that catalog and reads the ${KUEUE_OPERATOR_CHANNEL} channel: the
# head (the entry no other entry replaces or skips) is the upgrade target, and the
# CSV the head replaces is the upgrade source. The pair is exported for
# kueue-operator-test-upgrade-operator-art-install-previous (installs the source)
# and kueue-operator-test-upgrade-operator-art (approves the upgrade to the head).

function timestamp() { date -u --rfc-3339=seconds; }

CHANNEL="${KUEUE_OPERATOR_CHANNEL:-stable-v1.5}"

# kueue-operator-src ships jq/skopeo/git/wget but not yq; fetch the mikefarah yq
# binary (same approach as the disconnected cert-manager catalog step).
YQ=/tmp/yq
ARCH=$(uname -m)
case "${ARCH}" in
    x86_64) ARCH=amd64 ;;
    aarch64) ARCH=arm64 ;;
esac
wget -qO "${YQ}" "https://github.com/mikefarah/yq/releases/latest/download/yq_linux_${ARCH}"
chmod +x "${YQ}"

if [[ ! -s "${SHARED_DIR}/kueue_index_image" ]]; then
    echo "ERROR: ${SHARED_DIR}/kueue_index_image is missing or empty; kueue-operator-enable-catalogsource-art must run first"
    exit 1
fi
FBC_IMAGE="$(head -n 1 "${SHARED_DIR}/kueue_index_image")"
echo "[$(timestamp)] Resolving z-stream upgrade pair from ${FBC_IMAGE} (channel ${CHANNEL})..."

TMP_DIR=$(mktemp -d)
# The extracted tree is owned/moded by the base image; a non-root pod cannot
# always remove it, so keep cleanup best-effort.
trap 'rm -rf "${TMP_DIR}" 2>/dev/null || true' EXIT

# The art-fbc repo is public, so no auth is needed for the pull.
skopeo copy "docker://${FBC_IMAGE}" "dir:${TMP_DIR}/fbc"
mkdir -p "${TMP_DIR}/tree"
# The ART FBC is a full RHEL-based image, not a minimal catalog image. Extract
# only the catalog (*configs/*) rather than the whole rootfs: a non-root pod
# cannot overwrite the 0555 root-owned files a later layer restores over an
# earlier one (e.g. usr/bin/dnf), which makes a full `tar -xf` exit non-zero.
# --no-same-permissions keeps our files writable so later layers can overwrite
# them; `|| true` tolerates layers with no configs entry. The "no catalog found"
# check below is the real guard.
while read -r layer; do
    [[ -n "${layer}" ]] || continue
    tar -xf "${TMP_DIR}/fbc/${layer}" -C "${TMP_DIR}/tree" \
        --no-same-owner --no-same-permissions --wildcards '*configs/*' 2>/dev/null || true
done < <(jq -r '.layers[].digest | sub("^sha256:"; "")' "${TMP_DIR}/fbc/manifest.json")

# opm renders the FBC as catalog.yaml, catalog.yml or catalog.json; yq's default
# input-format "auto" picks the decoder from the extension.
CATALOG_FILE=""
for pattern in \
    "*/configs/kueue-operator/catalog.yaml" \
    "*/configs/kueue-operator/catalog.yml" \
    "*/configs/kueue-operator/catalog.json" \
    "*/configs/*/catalog.yaml" \
    "*/configs/*/catalog.yml" \
    "*/configs/*/catalog.json"; do
    CATALOG_FILE=$(find "${TMP_DIR}/tree" -path "${pattern}" | head -n 1)
    [[ -n "${CATALOG_FILE}" ]] && break
done
if [[ -z "${CATALOG_FILE}" ]]; then
    echo "ERROR: no configs/<package>/catalog.{yaml,yml,json} found in ${FBC_IMAGE}"
    find "${TMP_DIR}/tree" -maxdepth 3 -type d | head -n 20
    exit 1
fi
echo "Using catalog: ${CATALOG_FILE}"

CHANNEL_ENTRIES=$("${YQ}" -N -r "select(.schema == \"olm.channel\" and .name == \"${CHANNEL}\") | .entries[].name" "${CATALOG_FILE}")
if [[ -z "${CHANNEL_ENTRIES}" ]]; then
    echo "ERROR: channel ${CHANNEL} not found in the ART FBC; available channels:"
    "${YQ}" -N -r 'select(.schema == "olm.channel") | .name' "${CATALOG_FILE}"
    exit 1
fi

# The channel head is the entry no other entry replaces or skips.
CHANNEL_REPLACED=$("${YQ}" -N -r "select(.schema == \"olm.channel\" and .name == \"${CHANNEL}\") | .entries[] | .replaces // \"\"" "${CATALOG_FILE}")
CHANNEL_SKIPPED=$("${YQ}" -N -r "select(.schema == \"olm.channel\" and .name == \"${CHANNEL}\") | .entries[] | (.skips // [])[]" "${CATALOG_FILE}")
CHANNEL_REFERENCED=$(printf '%s\n%s\n' "${CHANNEL_REPLACED}" "${CHANNEL_SKIPPED}" | sed '/^$/d')

HEAD=$(printf '%s\n' "${CHANNEL_ENTRIES}" | while IFS= read -r name; do
    if ! printf '%s\n' "${CHANNEL_REFERENCED}" | grep -qxF "${name}"; then
        echo "${name}"
    fi
done)
HEAD_COUNT=$(printf '%s\n' "${HEAD}" | grep -c . || true)
if [[ "${HEAD_COUNT}" != "1" ]]; then
    echo "ERROR: channel ${CHANNEL} does not have exactly one head (found ${HEAD_COUNT}); refusing to guess"
    printf 'candidates:\n%s\n' "${HEAD}"
    exit 1
fi

PREVIOUS=$("${YQ}" -N -r "select(.schema == \"olm.channel\" and .name == \"${CHANNEL}\") | .entries[] | select(.name == \"${HEAD}\") | .replaces // \"\"" "${CATALOG_FILE}")
if [[ -z "${PREVIOUS}" ]]; then
    echo "ERROR: channel ${CHANNEL} head ${HEAD} declares no 'replaces'; no previous z-stream to upgrade from"
    exit 1
fi

echo "Upgrade source (previous): ${PREVIOUS}"
echo "Upgrade target (head):     ${HEAD}"
{
    echo "export KUEUE_UPGRADE_FROM_CSV=${PREVIOUS}"
    echo "export KUEUE_UPGRADE_TO_CSV=${HEAD}"
} >> "${SHARED_DIR}/env"
echo "[$(timestamp)] Resolved z-stream upgrade pair."
