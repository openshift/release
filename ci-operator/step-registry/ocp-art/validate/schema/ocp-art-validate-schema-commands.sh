#!/bin/bash

set -o nounset
set -o errexit
set -o pipefail

echo "=== ocp-build-data schema validation ==="

if [ -z "${PULL_BASE_SHA:-}" ]; then
    echo "PULL_BASE_SHA is not set. This check only runs in presubmit (PR) context."
    echo "Skipping validation."
    exit 0
fi

# Same file set the ocp-build-data GitHub Actions validate workflow watches:
# streams.yml, group.yml, releases.yml, bug.yml, rpms/**.yml, images/**.yml
CHANGED_FILES="$(git diff --diff-filter=d --name-only "${PULL_BASE_SHA}...HEAD" || true)"

if [ -z "${CHANGED_FILES}" ]; then
    echo "No changed files detected between ${PULL_BASE_SHA} and HEAD. Nothing to validate."
    exit 0
fi

echo "Changed files:"
echo "${CHANGED_FILES}"
echo ""

# If group.yml or streams.yml changed, every image/rpm meta needs revalidating
# because those files drive inheritance/merge behavior for the rest of the repo
# (mirrors ci-scripts/test's existing gitlab-ci logic).
if echo "${CHANGED_FILES}" | grep -qE '^(group|streams)\.yml$'; then
    echo "group.yml or streams.yml changed: validating all images/*.yml and rpms/*.yml"
    mapfile -t TARGETS < <(ls images/*.yml rpms/*.yml 2>/dev/null || true)
else
    mapfile -t TARGETS < <(echo "${CHANGED_FILES}" | grep -E '^(images|rpms)/.*\.yml$|^(releases|bug|group|streams)\.yml$' || true)
fi

if [ "${#TARGETS[@]}" -eq 0 ]; then
    echo "No ocp-build-data config files require validation. Skipping."
    exit 0
fi

echo "Files to validate:"
printf '  %s\n' "${TARGETS[@]}"
echo ""

export PATH="${HOME}/.local/bin:${PATH}"
if ! command -v uv &>/dev/null; then
    echo "uv not found on PATH; installing it (expected to already be baked into the step image)"
    pip install --user --quiet uv
fi

ART_TOOLS_DIR="$(mktemp -d)/art-tools"
echo "Cloning openshift-eng/art-tools into ${ART_TOOLS_DIR}..."
git clone --depth 1 --quiet https://github.com/openshift-eng/art-tools "${ART_TOOLS_DIR}"

echo "Running validate-ocp-build-data..."
uv run --project "${ART_TOOLS_DIR}" validate-ocp-build-data --images-dir images "${TARGETS[@]}"
