#!/usr/bin/env bash

set -e
set -u
set -o pipefail

# Offline ART build resolution for the disconnected e2e job.
#
# The Konflux variant of this step resolves the newest Konflux bundle tag and
# reads the images out of the bundle's CSV. The ART variant starts one level
# higher: it resolves the ART FBC (file-based catalog) floating tag to a digest,
# extracts the catalog from that image, and reads the channel head bundle plus
# the relatedImages the FBC already declares for it. That keeps this step free
# of cluster API calls and of stage credentials: the FBC comes from the public
# art-fbc repo, and kueue-operator-disconnected-install-art mirrors the stage
# digests with the vault credentials it already has.
#
# Outputs (appended to ${SHARED_DIR}/env):
#   BUNDLE_SOURCE_IMAGE, OPERATOR_SOURCE_IMAGE, OPERAND_SOURCE_IMAGE,
#   MUST_GATHER_SOURCE_IMAGE, ART_FBC_IMAGE, ART_BUNDLE_VERSION
# The resolved build is also recorded in tested-images.json (job artifacts).

function timestamp() {
    date -u --rfc-3339=seconds
}

TMP_DIR=$(mktemp -d)
trap 'rm -rf "${TMP_DIR}" || true' EXIT

FBC_REPO="${KUEUE_INDEX_IMAGE_REPO:-quay.io/redhat-user-workloads/ocp-art-tenant/art-fbc}"
FBC_TAG="${KUEUE_INDEX_IMAGE_TAG:-}"
CHANNEL="${KUEUE_OPERATOR_CHANNEL:-stable-v1.5}"

if [[ -n "${MULTISTAGE_PARAM_OVERRIDE_KUEUE_INDEX_IMAGE:-}" ]]; then
    FBC_REQUESTED="${MULTISTAGE_PARAM_OVERRIDE_KUEUE_INDEX_IMAGE}"
else
    if [[ -z "${FBC_TAG}" ]]; then
        echo "ERROR: KUEUE_INDEX_IMAGE_TAG is required (ART FBC floating tag, e.g. kueue-1.5__v4.22__kueue-rhel9-operator)"
        exit 1
    fi
    FBC_REQUESTED="${FBC_REPO}:${FBC_TAG}"
fi

# Resolve the reference to the digest of its top-level manifest. `skopeo inspect
# --raw` prints the bytes the registry serves, so hashing the file yields the
# index digest of the multi-arch ART FBC; the architecture-specific digest from
# a plain `skopeo inspect` does not identify the FBC.
function resolve_fbc_digest() {
    local ref="$1" manifest="${TMP_DIR}/fbc-manifest.json" attempt
    for attempt in 1 2 3 4 5; do
        if skopeo inspect --raw "docker://${ref}" > "${manifest}" 2>"${TMP_DIR}/inspect.err"; then
            sha256sum "${manifest}" | awk '{print "sha256:" $1}'
            return 0
        fi
        echo "WARN: resolving ${ref} failed (attempt ${attempt}/5); retrying..." >&2
        tail -n 3 "${TMP_DIR}/inspect.err" >&2 || true
        sleep $((attempt * 10))
    done
    echo "ERROR: could not resolve ${ref} to a digest" >&2
    return 1
}

# Repository part of a reference, with any tag or digest removed. Port-safe:
# the tag/digest separators are only looked for in the last path component.
function reference_repository() {
    local ref="$1" last="${1##*/}" prefix
    prefix="${ref%"${last}"}"
    last="${last%%@*}"
    last="${last%%:*}"
    echo "${prefix}${last}"
}

echo "[$(timestamp)] Resolving ART FBC ${FBC_REQUESTED}..."
if [[ "${FBC_REQUESTED}" == *"@"* ]]; then
    FBC_DIGEST="${FBC_REQUESTED##*@}"
else
    FBC_DIGEST=$(resolve_fbc_digest "${FBC_REQUESTED}")
fi
# The override keeps its own repository (never the default one), and the pinned
# reference is rebuilt as repository@digest: the docker transport rejects a
# reference carrying both a tag and a digest.
FBC_IMAGE="$(reference_repository "${FBC_REQUESTED}")@${FBC_DIGEST}"
echo "Resolved ART FBC: ${FBC_IMAGE}"

echo "[$(timestamp)] Extracting the FBC image..."
skopeo copy "docker://${FBC_IMAGE}" "dir:${TMP_DIR}/fbc"
mkdir -p "${TMP_DIR}/tree"
# Only the catalog tree is needed. Extracting every layer would also unpack the
# image's base OS (root-owned read-only directories) that the non-root step user
# cannot delete again, and a failed cleanup would mask a successful resolution.
while read -r layer; do
    [[ -n "${layer}" ]] || continue
    # Extract exactly the catalog members of each layer. Wildcard patterns are
    # unreliable here (a pattern that matches nothing makes tar exit non-zero),
    # and the base-OS layers are not needed at all.
    members=$(tar -tf "${TMP_DIR}/fbc/${layer}" | grep -E '(^|/)configs/' || true)
    if [[ -n "${members}" ]]; then
        printf '%s\n' "${members}" | tar -xf "${TMP_DIR}/fbc/${layer}" -C "${TMP_DIR}/tree" --no-recursion -T -
    fi
done < <(jq -r '.layers[].digest | sub("^sha256:"; "")' "${TMP_DIR}/fbc/manifest.json")

# opm renders the FBC as catalog.yaml, catalog.yml or catalog.json depending on
# the build; accept any of them (the kueue-operator package first, then any
# package). yq's default input-format "auto" picks the decoder from the file
# extension, so the yq queries below work regardless of which one is present.
find_catalog() {
    local pattern
    for pattern in \
        "*/configs/kueue-operator/catalog.yaml" \
        "*/configs/kueue-operator/catalog.yml" \
        "*/configs/kueue-operator/catalog.json" \
        "*/configs/*/catalog.yaml" \
        "*/configs/*/catalog.yml" \
        "*/configs/*/catalog.json"; do
        local match
        match=$(find "${TMP_DIR}/tree" -path "${pattern}" | head -n 1)
        if [[ -n "${match}" ]]; then
            echo "${match}"
            return 0
        fi
    done
    return 1
}
CATALOG_FILE=$(find_catalog || true)
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

# The channel head is the entry no other entry replaces or skips - the tip of
# the upgrade graph OLM walks, not the highest version string (a prerelease or
# a skipped entry can sort higher and is never installed by OLM).
CHANNEL_REPLACED=$(yq -N -r "select(.schema == \"olm.channel\" and .name == \"${CHANNEL}\") | .entries[] | .replaces // \"\"" "${CATALOG_FILE}")
CHANNEL_SKIPPED=$(yq -N -r "select(.schema == \"olm.channel\" and .name == \"${CHANNEL}\") | .entries[] | (.skips // [])[]" "${CATALOG_FILE}")
CHANNEL_REFERENCED=$(printf '%s\n%s\n' "${CHANNEL_REPLACED}" "${CHANNEL_SKIPPED}" | sed '/^$/d')

CHANNEL_HEADS=$(printf '%s\n' "${CHANNEL_ENTRIES}" | while IFS= read -r name; do
    if ! printf '%s\n' "${CHANNEL_REFERENCED}" | grep -qxF "${name}"; then
        echo "${name}"
    fi
done)
HEAD_COUNT=$(printf '%s\n' "${CHANNEL_HEADS}" | grep -c . || true)
if [[ "${HEAD_COUNT}" != "1" ]]; then
    echo "ERROR: channel ${CHANNEL} does not have exactly one head (found ${HEAD_COUNT}); refusing to guess"
    printf 'candidates:\n%s\n' "${CHANNEL_HEADS}"
    printf 'replaced/skipped:\n%s\n' "${CHANNEL_REFERENCED}"
    exit 1
fi
BUNDLE_NAME="${CHANNEL_HEADS}"
echo "Channel ${CHANNEL} head: ${BUNDLE_NAME}"

BUNDLE_IMAGE=$(yq -N -r "select(.schema == \"olm.bundle\" and .name == \"${BUNDLE_NAME}\") | .image" "${CATALOG_FILE}")
RELATED_IMAGES=$(yq -N -r "select(.schema == \"olm.bundle\" and .name == \"${BUNDLE_NAME}\") | .relatedImages[]? | .image" "${CATALOG_FILE}")

MUST_GATHER_IMAGE=$(printf '%s\n' "${RELATED_IMAGES}" | grep 'must-gather' | head -n 1 || true)
OPERATOR_IMAGE=$(printf '%s\n' "${RELATED_IMAGES}" | grep '/kueue-rhel9-operator[@:]' | head -n 1 || true)
OPERAND_IMAGE=$(printf '%s\n' "${RELATED_IMAGES}" | grep '/kueue-rhel9[@:]' | head -n 1 || true)

for reference in "BUNDLE_IMAGE=${BUNDLE_IMAGE}" "OPERATOR_IMAGE=${OPERATOR_IMAGE}" \
    "OPERAND_IMAGE=${OPERAND_IMAGE}" "MUST_GATHER_IMAGE=${MUST_GATHER_IMAGE}"; do
    name="${reference%%=*}"
    value="${reference#*=}"
    if [[ -z "${value}" ]]; then
        echo "ERROR: the FBC entry for ${BUNDLE_NAME} declares no ${name}"
        echo "FBC relatedImages for ${BUNDLE_NAME}:"
        printf '%s\n' "${RELATED_IMAGES}"
        exit 1
    fi
    # The FBC also points at registry.redhat.io/kueue-tech-preview for the old
    # channels; those images must never be selected or mirrored. Require the
    # digest here: install-art mirrors by digest and rewrites pulls with a
    # digest-based IDMS, so a tag-only reference would only fail later, after
    # these outputs have been recorded.
    if [[ ! "${value}" =~ ^registry\.redhat\.io/kueue/[^@]+@sha256:[0-9a-f]{64}$ ]]; then
        echo "ERROR: ${name}=${value} is not a digest-pinned image under registry.redhat.io/kueue"
        exit 1
    fi
done

function to_stage_registry() {
    echo "$1" | sed 's|^registry\.redhat\.io/|registry.stage.redhat.io/|'
}

BUNDLE_SOURCE_IMAGE=$(to_stage_registry "${BUNDLE_IMAGE}")
OPERATOR_SOURCE_IMAGE=$(to_stage_registry "${OPERATOR_IMAGE}")
OPERAND_SOURCE_IMAGE=$(to_stage_registry "${OPERAND_IMAGE}")
MUST_GATHER_SOURCE_IMAGE=$(to_stage_registry "${MUST_GATHER_IMAGE}")

echo "ART bundle:          ${BUNDLE_SOURCE_IMAGE}"
echo "ART operator image:  ${OPERATOR_SOURCE_IMAGE}"
echo "ART operand image:   ${OPERAND_SOURCE_IMAGE}"
echo "ART must-gather:     ${MUST_GATHER_SOURCE_IMAGE}"

{
    echo "export BUNDLE_SOURCE_IMAGE=${BUNDLE_SOURCE_IMAGE}"
    echo "export OPERATOR_SOURCE_IMAGE=${OPERATOR_SOURCE_IMAGE}"
    echo "export OPERAND_SOURCE_IMAGE=${OPERAND_SOURCE_IMAGE}"
    echo "export MUST_GATHER_SOURCE_IMAGE=${MUST_GATHER_SOURCE_IMAGE}"
    echo "export ART_FBC_IMAGE=${FBC_IMAGE}"
    echo "export ART_BUNDLE_VERSION=${BUNDLE_NAME}"
} >> "${SHARED_DIR}/env"

# Record what this run tested (requested tag, resolved FBC, selected bundle) so
# every run self-documents the ART build, mirroring the quay-gather convention.
jq -n \
    --arg requested "${FBC_REQUESTED}" \
    --arg fbc "${FBC_IMAGE}" \
    --arg channel "${CHANNEL}" \
    --arg version "${BUNDLE_NAME}" \
    --arg bundle "${BUNDLE_IMAGE}" \
    --arg operator "${OPERATOR_IMAGE}" \
    --arg operand "${OPERAND_IMAGE}" \
    --arg mustGather "${MUST_GATHER_IMAGE}" \
    '{requested: $requested, fbc: $fbc, channel: $channel, version: $version, bundle: $bundle,
      images: {operator: $operator, operand: $operand, mustGather: $mustGather}}' \
    > "${SHARED_DIR}/tested-images.json"
cat "${SHARED_DIR}/tested-images.json"
if [[ -n "${ARTIFACT_DIR:-}" && -d "${ARTIFACT_DIR}" ]]; then
    cp "${SHARED_DIR}/tested-images.json" "${ARTIFACT_DIR}/tested-images.json"
fi

echo "[$(timestamp)] ART build resolution completed."
