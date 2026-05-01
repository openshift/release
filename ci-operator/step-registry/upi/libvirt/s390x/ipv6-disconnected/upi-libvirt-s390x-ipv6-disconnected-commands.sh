#!/usr/bin/env bash

set -o nounset
set -o errexit
set -o pipefail

if [[ "${ENABLE_RELEASE_MIRROR}" != "true" ]]; then
  echo "ENABLE_RELEASE_MIRROR is not true; skipping oc adm release mirror."
  echo "Set ENABLE_RELEASE_MIRROR=true and MIRROR_RELEASE_IMAGE_REPO when the mirror registry is reachable from CI."
  exit 0
fi

if [[ -z "${MIRROR_RELEASE_IMAGE_REPO}" ]]; then
  echo "MIRROR_RELEASE_IMAGE_REPO must be set when ENABLE_RELEASE_MIRROR=true"
  exit 1
fi

unset KUBECONFIG

PULL_SECRET="${CLUSTER_PROFILE_DIR}/pull-secret"
if [[ ! -f "${PULL_SECRET}" ]]; then
  echo "pull-secret not found in CLUSTER_PROFILE_DIR"
  exit 1
fi

readable_version=$(oc adm release info "${RELEASE_IMAGE_LATEST}" -o jsonpath='{.metadata.version}')
echo "Mirroring release ${RELEASE_IMAGE_LATEST} (version ${readable_version}) to ${MIRROR_RELEASE_IMAGE_REPO}"

target_release_image_repo="${MIRROR_RELEASE_IMAGE_REPO}"
target_release_image="${target_release_image_repo}:${readable_version}"

mirror_log="${ARTIFACT_DIR}/oc-adm-release-mirror.log"
regex_keyword='imageContentSources'
mirror_crd_type='icsp'

args=(
  --from="${RELEASE_IMAGE_LATEST}"
  --to-release-image="${target_release_image}"
  --to="${target_release_image_repo}"
)

if [[ "${MIRROR_INSECURE}" == "true" ]]; then
  args+=(--insecure=true)
fi

if oc adm release mirror -h 2>/dev/null | grep -q -- '--keep-manifest-list'; then
  args+=(--keep-manifest-list=true)
fi

if oc adm release mirror -h 2>/dev/null | grep -q -- '--print-mirror-instructions'; then
  args+=(--print-mirror-instructions="${mirror_crd_type}")
fi

set -x
oc adm release mirror -a "${PULL_SECRET}" "${args[@]}" 2>&1 | tee "${mirror_log}"
set +x

echo "${target_release_image}" > "${SHARED_DIR}/mirrored-release-image.txt"
echo "Mirrored release image pullspec written to SHARED_DIR/mirrored-release-image.txt"

install_patch="${SHARED_DIR}/install-config-mirror-fragment.yaml"
line_num=$(grep -n "To use the new mirrored repository for upgrades" "${mirror_log}" | head -1 | cut -d: -f1 || true)
if [[ -n "${line_num}" ]] && [[ "${line_num}" =~ ^[0-9]+$ ]]; then
  install_end_line_num=$((line_num - 3))
  upgrade_start_line_num=$((line_num + 2))
  if [[ ${install_end_line_num} -gt 0 ]]; then
    sed -n "/^${regex_keyword}/,${install_end_line_num}p" "${mirror_log}" > "${install_patch}" || true
  fi
  sed -n "${upgrade_start_line_num},\$p" "${mirror_log}" > "${SHARED_DIR}/cluster-mirror-upgrade-fragment.txt" || true
else
  echo "Could not parse mirror log for install-config fragment; see ${mirror_log}"
  cp "${mirror_log}" "${SHARED_DIR}/release-mirror-full.log"
fi

if [[ -f "${install_patch}" ]] && [[ -s "${install_patch}" ]]; then
  echo "--- install-config mirror fragment ---"
  cat "${install_patch}"
fi
