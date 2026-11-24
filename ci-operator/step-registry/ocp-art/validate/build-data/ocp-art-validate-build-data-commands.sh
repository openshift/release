#!/bin/bash
set -o errexit
set -o nounset
set -o pipefail

: "${KONFLUX_APPLICATION:?Set KONFLUX_APPLICATION in the branch CI configuration}"

# Keep trusted validator code and dependencies outside the untrusted metadata checkout.
repo_root="${PWD}"
work_dir=$(mktemp -d)
trap 'rm -rf "${work_dir}"' EXIT
export UV_CACHE_DIR="${work_dir}/uv-cache"
export GIT_TERMINAL_PROMPT=0

art_tools_owner=openshift-eng
validator_revision="${ART_TOOLS_REF}"
if [[ "${validator_revision}" == *:* ]]; then
  art_tools_owner="${validator_revision%%:*}"
  validator_revision="${validator_revision#*:}"
fi

git init --quiet "${work_dir}/art-tools"
git -C "${work_dir}/art-tools" fetch --quiet --depth=1 \
  "https://github.com/${art_tools_owner}/art-tools.git" "${validator_revision}"
git -C "${work_dir}/art-tools" checkout --quiet --detach FETCH_HEAD
printf 'ART tools revision: '
git -C "${work_dir}/art-tools" rev-parse HEAD

validation_args=(
  --repo "${repo_root}"
  --report "${ARTIFACT_DIR}/validation.json"
)

# Keep schema and semantic validation for RHOSDT assembly updates. Use the
# full checks if images changed or the PR base is unavailable in this checkout.
if [[ "${PULL_BASE_REF:-}" == rhosdt-0.158 && "${PULL_BASE_SHA:-}" =~ ^[0-9a-f]{40}$ ]] &&
  git merge-base --is-ancestor "${PULL_BASE_SHA}" HEAD &&
  git diff --quiet --no-ext-diff --no-renames "${PULL_BASE_SHA}" HEAD -- images/; then
  echo 'Running local build-data validation for a non-image RHOSDT change.'
  validation_args+=(--base-ref "${PULL_BASE_SHA}" --schema-only)
else
  git clone --quiet --depth=1 --branch "${RELEASE_DATA_REF}" \
    https://gitlab.cee.redhat.com/releng/konflux-release-data.git "${work_dir}/release-data"
  validation_args+=(
    --rpa-root "${work_dir}/release-data/config"
    --application "${KONFLUX_APPLICATION}"
    --github-token-file /etc/github-private/oauth
    --registry-auth-file /var/run/secrets/ci-pull-credentials/.dockerconfigjson
  )
fi

# Validate the metadata checkout with the trusted art-tools validator.
uv run --project "${work_dir}/art-tools" --locked --no-dev python -I -m validator.ci \
  "${validation_args[@]}"
