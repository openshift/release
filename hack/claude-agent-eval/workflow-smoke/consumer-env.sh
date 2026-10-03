#!/bin/bash
# Test-image-only bootstrap: Bash sources this before the unchanged registry
# commands. Rehearsal metadata belongs to release; Git selection belongs to the
# pinned ai-helpers checkout. Do not install this in the shared runtime image.
set -euo pipefail
unset BASH_ENV

test "${REPO_OWNER}/${REPO_NAME}" = openshift/release
test "$(git rev-parse --show-toplevel)" = "${EVAL_WORKDIR}"
test "$(git remote get-url origin)" = https://github.com/openshift-eng/ai-helpers.git
test "$(git rev-parse HEAD)" = "${EVAL_SMOKE_HEAD}"
git merge-base --is-ancestor "${EVAL_SMOKE_BASE}" HEAD
test -f evals.yaml

mkdir -p "${ARTIFACT_DIR}/runner"
{
    echo "consumer_pr=https://github.com/openshift-eng/ai-helpers/pull/765"
    echo "consumer_base=${EVAL_SMOKE_BASE}"
    echo "consumer_head=${EVAL_SMOKE_HEAD}"
    echo "rehearsal_base=${PULL_BASE_SHA}"
    echo "rehearsal_head=${PULL_PULL_SHA}"
    git diff --name-only --no-renames "${EVAL_SMOKE_BASE}...HEAD" --
} > "${ARTIFACT_DIR}/runner/consumer-inputs.log"
export PULL_BASE_SHA="${EVAL_SMOKE_BASE}"
