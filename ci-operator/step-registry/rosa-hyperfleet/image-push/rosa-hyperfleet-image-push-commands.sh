#!/bin/bash

set -euo pipefail

AUTHFILE="/var/run/quay-push-credentials/.dockerconfigjson"
if [[ ! -r "${AUTHFILE}" ]]; then
  echo "ERROR: ${AUTHFILE} not found or not readable" >&2
  exit 1
fi

# Set up merged credentials: quay push + CI registry
export HOME=/tmp/home
export XDG_RUNTIME_DIR="${HOME}/run"
mkdir -p "$HOME/.docker" "${XDG_RUNTIME_DIR}/containers"
cp "${AUTHFILE}" "$HOME/.docker/config.json"
oc registry login

TAG="ci-${PULL_NUMBER:-0}-${BUILD_ID:-unknown}"

push_image() {
  local src="$1" repo="$2"
  local dest="${repo}:${TAG}"

  echo "Copying image to quay.io..."
  echo "  Source: ${src}"
  echo "  Destination: ${dest}"

  oc image mirror "${src}" "${dest}"

  if [[ -z "${PULL_NUMBER:-}" ]]; then
    local latest="${repo}:latest"
    echo "Postsubmit: also tagging as ${latest}"
    oc image mirror "${src}" "${latest}"
  fi

  echo "Image pushed successfully: ${dest}"
}

# Push primary component image
if [[ -n "${CI_COMPONENT_IMAGE:-}" ]] && [[ -n "${ROSA_REGIONAL_QUAY_DEST_REPO:-}" ]]; then
  push_image "${CI_COMPONENT_IMAGE}" "${ROSA_REGIONAL_QUAY_DEST_REPO}"
  echo "${ROSA_REGIONAL_QUAY_DEST_REPO}:${TAG}" > "${SHARED_DIR}/component-image-override"
fi

# Push extra component images from ROSA_REGIONAL_EXTRA_COMPONENTS
if [[ -n "${ROSA_REGIONAL_EXTRA_COMPONENTS:-}" ]]; then
  env_name=""
  while IFS= read -r line; do
    if [[ "$line" =~ ^-[[:space:]]+image:[[:space:]]*(.*) ]]; then
      env_name="${BASH_REMATCH[1]}"
    elif [[ -n "$env_name" && "$line" =~ ^[[:space:]]+repo:[[:space:]]*(.*) ]]; then
      repo="${BASH_REMATCH[1]}"
      src="${!env_name:-}"
      if [[ -z "${src}" ]]; then
        echo "WARNING: ${env_name} is not set, skipping"
      else
        push_image "${src}" "${repo}"
        echo "${repo}:${TAG}" >> "${SHARED_DIR}/extra-component-images"
      fi
      env_name=""
    fi
  done <<< "${ROSA_REGIONAL_EXTRA_COMPONENTS}"
fi
