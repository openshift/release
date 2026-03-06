#!/bin/bash
set -euo pipefail

# Only delete when we actually pushed (REPO path). No-op otherwise.
if [[ "${RESOURCE_AGENT_SOURCE:-RHCOS}" != "REPO" ]]; then
  echo "RESOURCE_AGENT_SOURCE is not REPO; skipping image delete."
  exit 0
fi

if [[ -z "${CUSTOM_OS_MIRROR_REGISTRY:-}" ]] || [[ -z "${CUSTOM_OS_IMAGE_REPO:-}" ]]; then
  echo "CUSTOM_OS_MIRROR_REGISTRY or CUSTOM_OS_IMAGE_REPO unset; skipping image delete."
  exit 0
fi

# Only support quay.io for tag deletion via API.
if [[ "${CUSTOM_OS_MIRROR_REGISTRY}" != "quay.io" ]]; then
  echo "Delete only supported for quay.io (got ${CUSTOM_OS_MIRROR_REGISTRY}); skipping."
  exit 0
fi

# Quay auth from profile (same as update step). equinix-edge-enablement: quay-custom-rhcos-secret.
AUTH_FILE="${CLUSTER_PROFILE_DIR:-}/quay-custom-rhcos-secret"
if [[ ! -f "${AUTH_FILE}" ]]; then
  echo "No quay-custom-rhcos-secret at CLUSTER_PROFILE_DIR; skipping image delete."
  exit 0
fi

# Extract Bearer token: Docker config has .auths["quay.io"].auth = base64(user:token)
QUAY_AUTH=$(jq -r '.auths["quay.io"].auth // empty' "${AUTH_FILE}")
if [[ -z "${QUAY_AUTH}" ]]; then
  echo "No quay.io auth in config; skipping image delete."
  exit 0
fi

# Decode and take the token (part after colon). Robot format is "org+robot" or "user:token".
DECODED=$(echo "${QUAY_AUTH}" | base64 -d 2>/dev/null || true)
if [[ -z "${DECODED}" ]]; then
  echo "Failed to decode quay auth; skipping image delete."
  exit 0
fi

TOKEN="${DECODED#*:}"
if [[ -z "${TOKEN}" ]] || [[ "${TOKEN}" == "${DECODED}" ]]; then
  echo "Could not extract token from auth; skipping image delete."
  exit 0
fi
# Do not log or echo TOKEN; it is used only in curl Authorization header.

# CUSTOM_OS_IMAGE_REPO is "org/repo" (e.g. rh-edge-enablement/tnf-custom-rhcos). Restrict to safe chars for API URLs.
SAFE_REPO_PATTERN='^[a-zA-Z0-9][a-zA-Z0-9_.-]*$'
NAMESPACE="${CUSTOM_OS_IMAGE_REPO%%/*}"
REPO_NAME="${CUSTOM_OS_IMAGE_REPO#*/}"
if [[ -z "${NAMESPACE}" ]] || [[ -z "${REPO_NAME}" ]]; then
  echo "Could not parse org/repo from CUSTOM_OS_IMAGE_REPO; skipping."
  exit 0
fi
if ! [[ "${NAMESPACE}" =~ ${SAFE_REPO_PATTERN} ]] || ! [[ "${REPO_NAME}" =~ ${SAFE_REPO_PATTERN} ]]; then
  echo "NAMESPACE or REPO_NAME contains invalid characters; skipping delete."
  exit 0
fi

# Extensions repo: default is same org, repo name with -extensions suffix.
EXTENSIONS_REPO="${CUSTOM_OS_EXTENSIONS_REPO:-${REPO_NAME}-extensions}"
if [[ "${EXTENSIONS_REPO}" == */* ]]; then
  EXT_NAMESPACE="${EXTENSIONS_REPO%%/*}"
  EXT_REPO="${EXTENSIONS_REPO#*/}"
else
  EXT_NAMESPACE="${NAMESPACE}"
  EXT_REPO="${EXTENSIONS_REPO}"
fi

delete_tag() {
  local ns="$1"
  local repo="$2"
  local tag="$3"
  local url="https://quay.io/api/v1/repository/${ns}/${repo}/tag/${tag}"
  if curl -sf -X DELETE -H "Authorization: Bearer ${TOKEN}" "${url}"; then
    echo "Deleted ${ns}/${repo}:${tag}"
  else
    echo "Could not delete ${ns}/${repo}:${tag} (may lack permission or tag missing)"
  fi
}

# 1. Delete this job's tag (written by update step) so our image is removed.
JOB_TAG_FILE="${SHARED_DIR:-/tmp}/custom-rhcos-image-tag"
if [[ -f "${JOB_TAG_FILE}" ]]; then
  JOB_TAG=$(cat "${JOB_TAG_FILE}" | tr -d '\n' | head -c 64)
  if [[ -n "${JOB_TAG}" ]] && [[ "${JOB_TAG}" =~ ^ts-[0-9]+$ ]]; then
    delete_tag "${NAMESPACE}" "${REPO_NAME}" "${JOB_TAG}"
    if [[ -n "${EXT_NAMESPACE}" ]] && [[ -n "${EXT_REPO}" ]]; then
      delete_tag "${EXT_NAMESPACE}" "${EXT_REPO}" "${JOB_TAG}"
    fi
  fi
fi

# 2. List tags and delete any older than 24 hours to keep the repo clean.
SECONDS_PER_DAY=86400
CUTOFF_TS=$(($(date +%s) - SECONDS_PER_DAY))

list_and_delete_stale_tags() {
  local ns="$1"
  local repo="$2"
  local page=1
  local tag_count resp has_additional
  while true; do
    resp=$(curl -sf -H "Authorization: Bearer ${TOKEN}" \
      "https://quay.io/api/v1/repository/${ns}/${repo}/tag/?limit=100&page=${page}" 2>/dev/null || true)
    if [[ -z "${resp}" ]]; then
      break
    fi
    tag_count=0
    # Quay v1 returns .tags[] with .name and .start_ts (Unix timestamp). Delete tags older than 24h.
    while read -r line; do
      tag_name=$(echo "${line}" | jq -r '.name // empty')
      start_ts=$(echo "${line}" | jq -r '.start_ts // empty' 2>/dev/null)
      if [[ -z "${tag_name}" ]]; then
        continue
      fi
      tag_count=$((tag_count + 1))
      if [[ -n "${start_ts}" ]] && [[ "${start_ts}" =~ ^[0-9]+$ ]] && [[ "${start_ts}" -lt "${CUTOFF_TS}" ]]; then
        delete_tag "${ns}" "${repo}" "${tag_name}"
      fi
    done < <(echo "${resp}" | jq -c '.tags[]? // empty' 2>/dev/null)
    has_additional=$(echo "${resp}" | jq -r '.has_additional // false' 2>/dev/null)
    if [[ "${has_additional}" != "true" ]] || [[ "${tag_count}" -eq 0 ]]; then
      break
    fi
    page=$((page + 1))
  done
}

list_and_delete_stale_tags "${NAMESPACE}" "${REPO_NAME}"
if [[ -n "${EXT_NAMESPACE}" ]] && [[ -n "${EXT_REPO}" ]]; then
  list_and_delete_stale_tags "${EXT_NAMESPACE}" "${EXT_REPO}"
fi

echo "Image cleanup done."
exit 0
