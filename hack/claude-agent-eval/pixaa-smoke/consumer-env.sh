#!/bin/bash
# Test-image bootstrap, sourced before the unchanged manifest registry commands.
# Prow reports on release; the runner selects evals from the pinned PIXAA PR diff.
set +x
set -euo pipefail
unset BASH_ENV

test "${REPO_OWNER}/${REPO_NAME}" = openshift/release
test "${EVAL_WORKDIR}" = /workspace
test "${EVAL_SMOKE_PR}" = 51
test -s /usr/local/github-credentials/oauth
cd "${EVAL_WORKDIR}"
test ! -e .git
mkdir -p "${ARTIFACT_DIR}/runner"

# Never put credentials in a remote URL, Git config, build layer, or artifact.
# The temporary helper only reads the already-mounted token when Git asks.
(
    auth_dir=$(mktemp -d)
    trap 'rm -rf "${auth_dir}"' EXIT
    cat > "${auth_dir}/askpass" <<'ASKPASS'
#!/bin/sh
case "$1" in
    *Username*) printf '%s\n' x-access-token ;;
    *Password*) cat /usr/local/github-credentials/oauth ;;
    *) exit 1 ;;
esac
ASKPASS
    chmod 700 "${auth_dir}/askpass"
    export GIT_ASKPASS="${auth_dir}/askpass" GIT_TERMINAL_PROMPT=0
    git init -q .
    git remote add origin https://github.com/openshift-eng/pixaa.git
    # Fetch the pinned base and head; do not follow a moving PR head silently.
    timeout 180 git -c credential.helper= fetch --no-tags --depth=50 origin \
        "${EVAL_SMOKE_BASE}" "${EVAL_SMOKE_HEAD}"
) > "${ARTIFACT_DIR}/runner/consumer-checkout.log" 2>&1 || {
    echo 'PIXAA checkout failed; see runner/consumer-checkout.log. Check private-git-cloner access to openshift-eng/pixaa.' >&2
    exit 1
}

git checkout -q --detach "${EVAL_SMOKE_HEAD}"
test "$(git rev-parse --show-toplevel)" = "${EVAL_WORKDIR}"
test "$(git rev-parse HEAD)" = "${EVAL_SMOKE_HEAD}"
git merge-base --is-ancestor "${EVAL_SMOKE_BASE}" HEAD
test -f evals.yaml
{
    echo "consumer_pr=https://github.com/openshift-eng/pixaa/pull/${EVAL_SMOKE_PR}"
    echo "consumer_base=${EVAL_SMOKE_BASE}"
    echo "consumer_head=${EVAL_SMOKE_HEAD}"
    echo "rehearsal_base=${PULL_BASE_SHA}"
    echo "rehearsal_head=${PULL_PULL_SHA}"
    git diff --name-only --no-renames "${EVAL_SMOKE_BASE}...HEAD" --
} > "${ARTIFACT_DIR}/runner/consumer-inputs.log"
export PULL_BASE_SHA="${EVAL_SMOKE_BASE}"
