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

git clone --quiet --depth=1 --branch "${RELEASE_DATA_REF}" \
  https://gitlab.cee.redhat.com/releng/konflux-release-data.git "${work_dir}/release-data"

git clone --quiet --depth=1 \
  https://gitlab.cee.redhat.com/releng/pyxis-repo-configs.git "${work_dir}/pyxis-repo-configs"
printf 'Pyxis configuration revision: '
git -C "${work_dir}/pyxis-repo-configs" rev-parse HEAD

# Validate the metadata checkout with the trusted art-tools validator.
uv run --project "${work_dir}/art-tools" --locked --no-dev python -I -m validator.ci \
  --repo "${repo_root}" \
  --rpa-root "${work_dir}/release-data/config" \
  --application "${KONFLUX_APPLICATION}" \
  --pyxis-root "${work_dir}/pyxis-repo-configs" \
  --github-token-file /etc/github-private/oauth \
  --registry-auth-file /var/run/secrets/ci-pull-credentials/.dockerconfigjson \
  --report "${ARTIFACT_DIR}/validation.json"
