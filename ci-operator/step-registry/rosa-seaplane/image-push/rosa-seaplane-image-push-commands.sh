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

# Smuggle the api chart SHA the same way as IMAGE_TAG: write it to
# SHARED_DIR for the provision step. Prefer ROSA_SEAPLANE_API_CHART_SHA
# when set; otherwise the rosa-seaplane-api commit from JOB_SPEC.
python3 <<'PYEOF'
import json, os, re

CHART_SOURCE_ORG = "openshift-online"
CHART_SOURCE_REPO = "rosa-seaplane-api"
shared = os.environ["SHARED_DIR"]


def valid(sha):
    return bool(re.fullmatch(r"[0-9a-fA-F]{40}", sha or ""))


def ref_sha(r):
    pulls = r.get("pulls") or []
    return (pulls[0].get("sha") if pulls else None) or r.get("base_sha") or ""


sha = os.environ.get("ROSA_SEAPLANE_API_CHART_SHA") or ""
if not valid(sha):
    spec = {}
    raw = os.environ.get("JOB_SPEC") or ""
    if raw:
        try:
            spec = json.loads(raw)
        except json.JSONDecodeError:
            spec = {}
    candidates = [r for r in [spec.get("refs"), *(spec.get("extra_refs") or [])] if r]
    api_refs = [
        r for r in candidates
        if r.get("org") == CHART_SOURCE_ORG and r.get("repo") == CHART_SOURCE_REPO
    ]
    ordered = [r for r in api_refs if r.get("workdir") is True] + [
        r for r in api_refs if r.get("workdir") is not True
    ]
    sha = ""
    for r in ordered:
        cand = ref_sha(r)
        if valid(cand):
            sha = cand
            break
if valid(sha):
    path = os.path.join(shared, "rosa-seaplane-api-chart-sha")
    with open(path, "w") as f:
        f.write(sha)
    print(f"Wrote api chart SHA {sha} to {path}")
PYEOF
