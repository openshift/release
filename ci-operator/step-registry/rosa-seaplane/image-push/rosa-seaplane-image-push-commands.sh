#!/bin/bash

set -euo pipefail

if [[ -z "${ROSA_REGIONAL_COMPONENTS:-}" ]]; then
  echo "ROSA_REGIONAL_COMPONENTS is not set, nothing to push."
  exit 0
fi

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

# Push the images listed in ROSA_REGIONAL_COMPONENTS. Each entry's
# "image" names the env var (a CI_IMAGE_N dependency) holding the source
# pullspec and "repo" the quay.io destination. Entries must start with
# "image:"; the provision step also fails on any entry left unpushed.
env_name=""
while IFS= read -r line; do
  if [[ "$line" =~ ^-[[:space:]]+image:[[:space:]]*(.*) ]]; then
    env_name="${BASH_REMATCH[1]}"
  elif [[ -z "$env_name" && "$line" =~ ^-?[[:space:]]+repo: ]]; then
    echo "ERROR: ROSA_REGIONAL_COMPONENTS entries must start with 'image:' (found '${line}')" >&2
    exit 1
  elif [[ -n "$env_name" && "$line" =~ ^[[:space:]]+repo:[[:space:]]*(.*) ]]; then
    repo="${BASH_REMATCH[1]}"
    if [[ ! "${env_name}" =~ ^CI_IMAGE_[1-8]$ ]] || [[ -z "${!env_name:-}" ]]; then
      echo "ERROR: image: ${env_name} must be one of CI_IMAGE_1..CI_IMAGE_8, mapped in steps.dependencies" >&2
      exit 1
    fi
    push_image "${!env_name}" "${repo}"
    echo "${repo}:${TAG}" >> "${SHARED_DIR}/component-images"
    env_name=""
  fi
done <<< "${ROSA_REGIONAL_COMPONENTS}"
