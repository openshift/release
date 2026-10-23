#!/usr/bin/env bash
# Run in a DPTP image with Linux user namespaces available. Uses fake secrets
# and a local Responses fixture; never contacts a model or mutates GitHub.
set -euo pipefail

repo_root=$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)
test_dir=$(mktemp -d /tmp/dptp-isolation-test.XXXXXX)
test_codex_home=""
test_agent_home=""
fixture_pid=""
cleanup() {
    local rc=$?
    if [[ "${rc}" -ne 0 ]]; then
        echo 'FAIL: native Codex isolation fixture' >&2
        for diagnostic in "${test_codex_home}/codex-stderr.log" "${test_dir}/worker.jsonl"; do
            [[ ! -f "${diagnostic}" ]] || tail -15 "${diagnostic}" >&2
        done
    fi
    if [[ -n "${fixture_pid}" ]]; then
        kill "${fixture_pid}" 2>/dev/null || true
        wait "${fixture_pid}" 2>/dev/null || true
    fi
    [[ -z "${test_codex_home}" ]] || rm -rf "${test_codex_home}"
    [[ -z "${test_agent_home}" ]] || rm -rf "${test_agent_home}"
    rm -rf "${test_dir}"
}
trap cleanup EXIT

export WORKDIR="${test_dir}/workspace" SHARED_DIR="${test_dir}/shared" ARTIFACT_DIR="${test_dir}/artifacts"
export HOME="${test_dir}/home"
mkdir -p "${WORKDIR}/artifacts" "${SHARED_DIR}" "${ARTIFACT_DIR}" "${HOME}"
cd "${WORKDIR}"
git init -q
git config user.name Fixture
git config user.email fixture@example.invalid
printf 'baseline\n' > baseline
git add baseline
git commit -qm baseline
mkdir -p .codex
printf 'model_provider = "forbidden-project-provider"\n' > .codex/config.toml
printf '#!/bin/sh\nexit 1\n' > .git/hooks/pre-commit
chmod +x .git/hooks/pre-commit

awk '
    /^EXTRACT_METRICS=/ { copying = 1 }
    /^HEREDOC_EOF$/ && copying { exit }
    copying { print }
' "${repo_root}/ci-operator/step-registry/openshift/agentic/dptp/init/openshift-agentic-dptp-init-commands.sh" > "${test_dir}/helper.sh"
# shellcheck source=/dev/null
source "${test_dir}/helper.sh"
refresh_github_tokens() { :; }
export AGENT_HARNESS=codex CODEX_MODEL=gpt-5.6-sol CODEX_GATE_MODEL=gpt-5.6-sol AGENT_EFFORT=high
export UPSTREAM_REPO=acme/widgets PR_NUM=42
export JIRA_ISSUE_KEY=TEST-1
export OPENAI_API_KEY_PATH="${SHARED_DIR}/openai-key"
printf 'fake-isolation-openai-canary' > "${OPENAI_API_KEY_PATH}"
printf 'fake-isolation-github-canary' > "${SHARED_DIR}/gh-upstream-token"
initialize_agent > /dev/null
test_codex_home="${CODEX_HOME}"
test_agent_home="${CODEX_AGENT_HOME}"

go build -o "${test_dir}/responses-fixture" "${repo_root}/hack/dptp-codex-isolation-test-server.go"
"${test_dir}/responses-fixture" "${test_dir}" "${WORKDIR}" "${SHARED_DIR}" "${CODEX_HOME}" > "${test_dir}/fixture.log" 2>&1 &
fixture_pid=$!
for attempt in {1..100}; do
    [[ -s "${test_dir}/endpoint" ]] && break
    if ! kill -0 "${fixture_pid}" 2>/dev/null; then
        echo "FAIL: Responses fixture exited before readiness (attempt ${attempt})" >&2
        exit 1
    fi
    sleep 0.1
done
[[ -s "${test_dir}/endpoint" ]]
printf 'model_provider = "fixture"\n[model_providers.fixture]\nname = "Local fixture"\nbase_url = "%s"\nwire_api = "responses"\nrequires_openai_auth = false\n' "$(cat "${test_dir}/endpoint")" > "${CODEX_HOME}/config.toml"
export GATE_PROMPT="${test_dir}/instructions.md"
printf 'Fixture instructions.\n' > "${GATE_PROMPT}"

cat > "${WORKDIR}/isolation-probe.sh" <<'PROBE'
set -euo pipefail
[[ -z "${CODEX_API_KEY:-}" && -z "${GITHUB_TOKEN:-}" && -z "${GH_FORK_TOKEN:-}" ]]
for path in "$1/gh-upstream-token" "$1/openai-key" "$2/config.toml" "$2/dptp-pipeline.config.toml" /var/run/github-token /var/run/claude-code-service-account /var/run/codex-openai-api-key /var/run/registry-pull-credentials; do
    if [[ -r "${path}" ]]; then
        echo 'FAIL: credential directory is readable'
        exit 1
    fi
done
if grep -saql 'fake-isolation-.*-canary' /proc/[0-9]*/environ; then
    echo 'FAIL: supervisor credentials are visible through procfs'
    exit 1
fi
if touch .git/forbidden-write 2>/dev/null || mv .git stolen-git 2>/dev/null; then
    echo 'FAIL: Git metadata is writable'
    exit 1
fi
gh api meta --jq '.installed_version' | grep -qx '3.16.0'
if curl -fsS --connect-timeout 2 --max-time 4 --noproxy '*' http://169.254.169.254/dptp-isolation-probe >/dev/null 2>&1; then
    echo 'FAIL: direct metadata-service access succeeded'
    exit 1
fi
printf 'isolated workspace write\n' > isolation-passed
echo 'PASS: credential-free command, protected Git metadata, broker access, and workspace write'
# Plant links that would disclose secrets if the pipeline followed them outside
# the sandbox, including a link replacing the entire artifact directory.
ln -s "$1/openai-key" artifacts/pr-description.md
ln -s "$1/gh-upstream-token" artifacts/credential-link
PROBE

agentic_ci --timeout 60 'run fixture isolation probe' --append-system-prompt-file "${GATE_PROMPT}" > "${test_dir}/worker.jsonl"
[[ -f "${WORKDIR}/isolation-passed" ]]
rg -q '"exit_code":0' "${test_dir}/worker.jsonl"
if read_codex_artifact "${WORKDIR}/artifacts/pr-description.md" > "${test_dir}/description" 2>/dev/null; then
    echo 'FAIL: PR description followed a private credential symlink' >&2
    exit 1
fi
copy_agent_artifacts
if [[ -e "${ARTIFACT_DIR}/credential-link" || -L "${ARTIFACT_DIR}/credential-link" ]]; then
    echo 'FAIL: credential symlink reached published artifacts' >&2
    exit 1
fi
rm "${WORKDIR}/artifacts/pr-description.md"
printf 'Safe PR description\n' > "${WORKDIR}/artifacts/pr-description.md"
read_codex_artifact "${WORKDIR}/artifacts/pr-description.md" > "${test_dir}/description"
cmp "${test_dir}/description" "${WORKDIR}/artifacts/pr-description.md"
copy_agent_artifacts
cmp "${ARTIFACT_DIR}/pr-description.md" "${WORKDIR}/artifacts/pr-description.md"
mv artifacts artifacts-original
ln -s "${SHARED_DIR}" artifacts
copy_agent_artifacts
if [[ -e "${ARTIFACT_DIR}/openai-key" || -e "${ARTIFACT_DIR}/gh-upstream-token" ]]; then
    echo 'FAIL: artifact directory redirected the publisher to credentials' >&2
    exit 1
fi
rm artifacts
mv artifacts-original artifacts
commit_codex_changes > /dev/null
git diff --exit-code HEAD -- isolation-passed
if git ls-tree -r --name-only HEAD | rg -q '^artifacts/'; then
    echo 'FAIL: runtime artifacts were committed' >&2
    exit 1
fi
agent_gate 'fixture gate' > "${test_dir}/gate.txt"
[[ $(cat "${test_dir}/gate.txt") == $'COMMENT_WORK=no\nCI_WORK=no\nFAILING_CHECKS=[]' ]]
echo 'PASS: pinned Codex worker and gate enforce the generated isolation profile'
