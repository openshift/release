#!/bin/bash
set -o errexit
set -o nounset
set -o pipefail

# Keep trusted validator code and dependencies outside the untrusted metadata checkout.
repo_root="${PWD}"
work_dir=$(mktemp -d)
trap 'rm -rf "${work_dir}"' EXIT
export UV_CACHE_DIR="${work_dir}/uv-cache"
export UV_PROJECT_ENVIRONMENT="${work_dir}/venv"
export GIT_TERMINAL_PROMPT=0

git init --quiet "${work_dir}/art-tools"
git -C "${work_dir}/art-tools" remote add origin https://github.com/openshift-eng/art-tools.git
git -C "${work_dir}/art-tools" fetch --quiet --depth=1 origin "${ART_TOOLS_REF}"
git -C "${work_dir}/art-tools" checkout --quiet --detach FETCH_HEAD
printf 'ART tools revision: '
git -C "${work_dir}/art-tools" rev-parse HEAD
uv sync --project "${work_dir}/art-tools" --locked --no-dev

git clone --quiet --depth=1 --branch "${RELEASE_DATA_REF}" \
  https://gitlab.cee.redhat.com/releng/konflux-release-data.git "${work_dir}/release-data"

application="${KONFLUX_APPLICATION:-}"
if [[ -z "${application}" ]]; then
  : "${PULL_BASE_REF:?PULL_BASE_REF or KONFLUX_APPLICATION is required}"
  application="${PULL_BASE_REF//./-}"
fi

# Validate all metadata during the initial optional rollout to reveal baseline gaps.
# The CLI also supports --base-ref for changed-file validation after the baseline audit.
"${UV_PROJECT_ENVIRONMENT}/bin/python" -I -m validator.ci \
  --repo "${repo_root}" \
  --github-token-file /var/run/art-build-data-validation/token \
  --rpa-root "${work_dir}/release-data/config" \
  --application "${application}" \
  --report "${ARTIFACT_DIR}/validation.json"
