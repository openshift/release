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

if [[ ! -s "${SHARED_DIR}/kueue_index_image" ]]; then
    echo "ERROR: ${SHARED_DIR}/kueue_index_image is missing or empty; kueue-operator-enable-catalogsource-art must run first"
    exit 1
fi
FBC_IMAGE="$(head -n 1 "${SHARED_DIR}/kueue_index_image")"
echo "[$(timestamp)] Resolving z-stream upgrade pair from ${FBC_IMAGE} (channel ${CHANNEL})..."

TMP_DIR=$(mktemp -d)
trap 'rm -rf "${TMP_DIR}"' EXIT

# The art-fbc repo is public, so no auth is needed for the pull.
skopeo copy "docker://${FBC_IMAGE}" "dir:${TMP_DIR}/fbc"
mkdir -p "${TMP_DIR}/tree"
while read -r layer; do
    [[ -n "${layer}" ]] || continue
    tar -xf "${TMP_DIR}/fbc/${layer}" -C "${TMP_DIR}/tree"
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

CHANNEL_ENTRIES=$(yq -N -r "select(.schema == \"olm.channel\" and .name == \"${CHANNEL}\") | .entries[].name" "${CATALOG_FILE}")
if [[ -z "${CHANNEL_ENTRIES}" ]]; then
    echo "ERROR: channel ${CHANNEL} not found in the ART FBC; available channels:"
    yq -N -r 'select(.schema == "olm.channel") | .name' "${CATALOG_FILE}"
    exit 1
fi

# The channel head is the entry no other entry replaces or skips.
CHANNEL_REPLACED=$(yq -N -r "select(.schema == \"olm.channel\" and .name == \"${CHANNEL}\") | .entries[] | .replaces // \"\"" "${CATALOG_FILE}")
CHANNEL_SKIPPED=$(yq -N -r "select(.schema == \"olm.channel\" and .name == \"${CHANNEL}\") | .entries[] | (.skips // [])[]" "${CATALOG_FILE}")
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

PREVIOUS=$(yq -N -r "select(.schema == \"olm.channel\" and .name == \"${CHANNEL}\") | .entries[] | select(.name == \"${HEAD}\") | .replaces // \"\"" "${CATALOG_FILE}")
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
