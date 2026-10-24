#!/bin/bash
# Rehearsal bootstrap, sourced by the smoke test's inline step right before it
# runs the merged manifest registry commands unchanged. Prow reports on
# release; the runner selects evals from the pinned PIXAA PR diff.
set +x
set -euo pipefail
# Bare test assertions exit silently under set -e; say which one failed.
trap 'echo "PIXAA rehearsal bootstrap failed at ${BASH_SOURCE[0]}:${LINENO}" >&2' ERR

# openshift-eng/pixaa#51 (pixaa-23-manifest-consumer-smoke) and its merge base
# with pixaa main. Pin each rehearsal explicitly; never follow a moving head.
EVAL_SMOKE_PR=51
EVAL_SMOKE_HEAD=5fa51075185c6ac51bddb6b9778ecf15dcea81ba
EVAL_SMOKE_BASE=c88c63715cdc84e3fb5360c6094a5c49468e3e8c

test "${REPO_OWNER}/${REPO_NAME}" = openshift/release
test "${EVAL_WORKDIR}" = /workspace
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
