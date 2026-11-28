#!/usr/bin/env bash
# Exercise DPTP harness dispatch without model calls or GitHub mutations.
set -euo pipefail

repo_root=$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)
test_dir=$(mktemp -d)
test_codex_home=""
test_codex_agent_home=""
cleanup() {
    [[ -z "${test_codex_home}" ]] || rm -rf "${test_codex_home}"
    [[ -z "${test_codex_agent_home}" ]] || rm -rf "${test_codex_agent_home}"
    rm -rf "${test_dir}"
}
trap cleanup EXIT

export SHARED_DIR="${test_dir}/shared" ARTIFACT_DIR="${test_dir}/artifacts"
export WORKDIR="${test_dir}/workspace"
export HOME="${test_dir}/home"
mkdir -p "${SHARED_DIR}" "${ARTIFACT_DIR}" "${WORKDIR}/artifacts" "${test_dir}/bin" "${HOME}"
git -C "${WORKDIR}" init -q
# Extract the actual helper shipped by init, including nested heredocs.
awk '
    /^EXTRACT_METRICS=/ { copying = 1 }
    /^HEREDOC_EOF$/ && copying { exit }
    copying { print }
' "${repo_root}/ci-operator/step-registry/openshift/agentic/dptp/init/openshift-agentic-dptp-init-commands.sh" > "${test_dir}/helper.sh"
# shellcheck source=/dev/null
source "${test_dir}/helper.sh"

refresh_github_tokens() {
    printf 'refresh\n' >> "${test_dir}/refreshes"
}

cat > "${test_dir}/bin/codex" <<'MOCK'
#!/usr/bin/env bash
set -euo pipefail
[[ "${CODEX_API_KEY}" == fake-test-api-key ]]
printf '%s\n' "$@" > "${MOCK_ARGS}"
cat > "${MOCK_PROMPT}"
last_message=""
while [[ $# -gt 0 ]]; do
    if [[ "$1" == --output-last-message ]]; then
        last_message=$2
        shift
    fi
    shift
done
printf 'COMMENT_WORK=no\nCI_WORK=no\nFAILING_CHECKS=[]\n' > "${last_message}"
# Intermediate output must never be parsed as the gate decision.
printf '{"type":"item.completed","text":"COMMENT_WORK=yes"}\n'
exit "${MOCK_EXIT:-0}"
MOCK
cat > "${test_dir}/bin/agentic-ci" <<'MOCK'
#!/usr/bin/env bash
set -euo pipefail
printf '%s\n' "$@" > "${MOCK_ARGS}"
exit "${MOCK_EXIT:-0}"
MOCK
chmod +x "${test_dir}/bin/"*
export PATH="${test_dir}/bin:${PATH}"
export CODEX_BIN="${test_dir}/bin/codex"
export MOCK_ARGS="${test_dir}/args" MOCK_PROMPT="${test_dir}/prompt"
export OPENAI_API_KEY_PATH="${test_dir}/api-key"
printf 'fake-test-api-key' > "${OPENAI_API_KEY_PATH}"
export CLAUDE_MODEL=claude-worker GATE_MODEL=claude-gate ALLOWED_TOOLS=Bash
export CODEX_MODEL=codex-worker CODEX_GATE_MODEL=codex-gate
export UPSTREAM_REPO=acme/widgets PR_NUM=42
export GATE_PROMPT="${test_dir}/gate.md"
printf 'Inlined gate process\n' > "${GATE_PROMPT}"

assert_equal() {
    if [[ "$1" != "$2" ]]; then
        echo "FAIL: $3 (expected '$2', got '$1')" >&2
        exit 1
    fi
}

initialize_agent > /dev/null
assert_equal "${AGENT_HARNESS}" claude-code 'default harness'
assert_equal "${AGENT_EFFORT}" high 'default effort'
agentic_ci --timeout 5 'solve' --output-format stream-json > /dev/null
rg -q -x claude-code "${MOCK_ARGS}"
rg -q -x claude-worker "${MOCK_ARGS}"
rg -q -x -- --effort "${MOCK_ARGS}"
rg -q -x high "${MOCK_ARGS}"
echo 'PASS: Claude remains the default'

export MULTISTAGE_PARAM_OVERRIDE_AGENT_HARNESS=codex
export MULTISTAGE_PARAM_OVERRIDE_AGENT_MODEL=custom-worker
export MULTISTAGE_PARAM_OVERRIDE_AGENT_GATE_MODEL=custom-gate
export MULTISTAGE_PARAM_OVERRIDE_AGENT_EFFORT=medium
initialize_agent > /dev/null
assert_equal "${AGENT_MODEL}" custom-worker 'worker override'
test_codex_home="${CODEX_HOME}"
test_codex_agent_home="${CODEX_AGENT_HOME}"
assert_equal "${AGENT_GATE_MODEL}" custom-gate 'gate override'
export CODEX_DENY_GH=true
agentic_ci --timeout 5 'solve the issue' --settings ignored.json \
    --append-system-prompt-file "${GATE_PROMPT}" --output-format stream-json > "${test_dir}/stdout"
rg -q -x custom-worker "${MOCK_ARGS}"
rg -q -x model_reasoning_effort=medium "${MOCK_ARGS}"
rg -q -x -- --profile "${MOCK_ARGS}"
rg -q -x dptp-pipeline "${MOCK_ARGS}"
rg -q 'Inlined gate process' "${CODEX_HOME}/dptp-pipeline.config.toml"
if rg -q 'Inlined gate process|developer_instructions=' "${MOCK_ARGS}"; then
    echo 'FAIL: pipeline instructions were passed through argv' >&2
    exit 1
fi
if rg -q 'Inlined gate process' "${MOCK_PROMPT}"; then
    echo 'FAIL: pipeline instructions were downgraded to user input' >&2
    exit 1
fi
rg -q 'solve the issue' "${MOCK_PROMPT}"
if rg -q -- '--settings|--append-system-prompt-file|--output-format' "${MOCK_ARGS}"; then
    echo 'FAIL: Claude-only flags reached Codex' >&2
    exit 1
fi
rg -q 'pattern = \["gh"\]' "${CODEX_HOME}/rules/dptp.rules"
rg -q 'default_permissions = "dptp"' "${CODEX_HOME}/dptp-pipeline.config.toml"
rg -q 'inherit = "none"' "${CODEX_HOME}/dptp-pipeline.config.toml"
if rg -q 'danger-full-access|--sandbox' "${MOCK_ARGS}"; then
    echo 'FAIL: unrestricted sandbox reached Codex' >&2
    exit 1
fi
echo 'PASS: Codex selection, overrides, prompts, and solver rules'

export CODEX_DENY_GH=false CODEX_DENY_PUSH=true
agent_gate 'check review work' > "${test_dir}/gate-output"
assert_equal "$(cat "${test_dir}/gate-output")" $'COMMENT_WORK=no\nCI_WORK=no\nFAILING_CHECKS=[]' 'final gate output only'
rg -q -x custom-gate "${MOCK_ARGS}"
rg -q 'pattern = \["git", "push"\]' "${CODEX_HOME}/rules/dptp.rules"
echo 'PASS: gate uses its own model and only parses the final response'

agentic_ci --timeout 5 'wrap up' --continue --max-turns 10 > /dev/null
rg -q -x resume "${MOCK_ARGS}"
rg -q -x -- --last "${MOCK_ARGS}"
rg -q 'Inlined gate process' "${CODEX_HOME}/dptp-pipeline.config.toml"
echo 'PASS: continuation resumes the current step session and keeps pipeline instructions'

large_prompt="${test_dir}/large-system-prompt.md"
head -c 140000 /dev/zero | tr '\0' 'X' > "${large_prompt}"
printf '\nQuotes: "example"; backslash: \\; tab:\t; unicode: žluťoučký\n' >> "${large_prompt}"
agentic_ci --timeout 5 'solve with large instructions' \
    --append-system-prompt-file "${large_prompt}" --output-format stream-json > /dev/null
sed -n 's/^developer_instructions = //p' "${CODEX_HOME}/dptp-pipeline.config.toml" \
    | jq -rj . > "${test_dir}/decoded-instructions"
printf '%s\n\n' 'Use shell commands and file tools to carry out the inlined process. Read referenced SKILL.md files directly; do not invoke Claude-only Skill or slash commands.' \
    > "${test_dir}/expected-instructions"
cat "${large_prompt}" >> "${test_dir}/expected-instructions"
printf '\n\n%s\n' 'Codex CI isolation: edit and test workspace files only. Git metadata is read-only. Do not create branches, commit, push, pull, or run git fetch. The pipeline handles commits and pushes. GitHub access uses a scoped broker: read metadata and post replies only; do not invoke GraphQL mutations or gh auth commands. Credentials are deliberately unavailable to commands.' >> "${test_dir}/expected-instructions"
cmp "${test_dir}/expected-instructions" "${test_dir}/decoded-instructions"
cp "${CODEX_HOME}/dptp-instructions.toml" "${test_dir}/large-config.toml"
agentic_ci --timeout 5 'continue with large instructions' --continue > /dev/null
cmp "${test_dir}/large-config.toml" "${CODEX_HOME}/dptp-instructions.toml"
assert_equal "$(stat -c '%a' "${CODEX_HOME}/dptp-pipeline.config.toml")" 600 'config permissions'
if rg -q 'developer_instructions=|XXXX' "${MOCK_ARGS}" "${MOCK_PROMPT}"; then
    echo 'FAIL: large instructions were passed through argv or user input' >&2
    exit 1
fi
echo 'PASS: large instructions retain their contents and launch/resume through a private config file'

for expected_exit in 1 124; do
    export MOCK_EXIT="${expected_exit}"
    actual_exit=0
    agentic_ci --timeout 5 'fail' > /dev/null || actual_exit=$?
    assert_equal "${actual_exit}" "${expected_exit}" 'worker failure status'
    actual_exit=0
    agent_gate 'failed gate' > "${test_dir}/failed-gate" || actual_exit=$?
    assert_equal "${actual_exit}" "${expected_exit}" 'gate failure status'
    [[ ! -s "${test_dir}/failed-gate" ]]
done
unset MOCK_EXIT
echo 'PASS: failures and timeouts propagate without stale gate decisions'

actual_exit=0
agentic_ci --timeout 5 'unsupported' --unexpected > /dev/null 2>&1 || actual_exit=$?
assert_equal "${actual_exit}" 2 'unsupported adapter option'
actual_exit=0
agentic_ci --no-streaming 'unsupported wrapper option' > /dev/null 2>&1 || actual_exit=$?
assert_equal "${actual_exit}" 2 'unsupported wrapper option'
export MULTISTAGE_PARAM_OVERRIDE_AGENT_HARNESS=unknown
actual_exit=0
initialize_agent > /dev/null 2>&1 || actual_exit=$?
assert_equal "${actual_exit}" 1 'invalid harness'
export MULTISTAGE_PARAM_OVERRIDE_AGENT_HARNESS=codex
: > "${OPENAI_API_KEY_PATH}"
actual_exit=0
initialize_agent > /dev/null 2>&1 || actual_exit=$?
assert_equal "${actual_exit}" 1 'empty key'
if rg -q 'fake-test-api-key' "${WORKDIR}/artifacts" "${test_dir}/stdout"; then
    echo 'FAIL: API key was logged' >&2
    exit 1
fi
echo 'PASS: invalid settings and missing credentials fail without leaking the key'

# Check emitted JUnit against both new Codex records and old Claude records.
for harness in codex claude-code; do
    if [[ "${harness}" == codex ]]; then
        exit_field=agent_exit
        expected_name=Codex
    else
        exit_field=claude_exit
        expected_name=Claude
    fi
    jq -n --arg harness "${harness}" --arg exit_field "${exit_field}" '
        {agent: "dptp-jira-solver", phase: "solve", issue_key: "DPTP-1",
         result: "failed", upstream_repo: "openshift/release", harness: $harness,
         phase_durations: {setup: 1, solve: 2, pr: 0}, ($exit_field): 124}
    ' > "${SHARED_DIR}/metrics-metadata-solve.json"
    bash "${repo_root}/ci-operator/step-registry/openshift/agentic/dptp/emit-metrics/openshift-agentic-dptp-emit-metrics-commands.sh" > /dev/null
    rg -q "${expected_name} timed out" "${ARTIFACT_DIR}/junit_agentic-dptp-solve.xml"
    rg -q 'failures="1"' "${ARTIFACT_DIR}/junit_agentic-dptp-solve.xml"
done
echo 'PASS: JUnit identifies Codex and supports existing Claude metadata'

(
    awk '
        /^GITHUB_APP_CRED_DIR=/ { copying = 1 }
        /^HEREDOC_EOF$/ && copying { exit }
        copying { print }
    ' "${repo_root}/ci-operator/step-registry/openshift/agentic/dptp/github-app-auth/openshift-agentic-dptp-github-app-auth-commands.sh" > "${test_dir}/auth-helper.sh"
    # shellcheck source=/dev/null
    source "${test_dir}/auth-helper.sh"
    # shellcheck disable=SC2329 # Invoked by the sourced token helper.
    generate_jwt() { printf 'fake-jwt'; }
    export GITHUB_APP_CRED_DIR="${test_dir}/app-credentials"
    export SCOPE_REQUESTS="${test_dir}/scope-requests.jsonl"
    export UPSTREAM_REPO=acme/widgets FORK_REPO=acme-fork/widgets-fork AGENT_HARNESS=codex
    mkdir -p "${GITHUB_APP_CRED_DIR}" "${test_dir}/scope-bin"
    printf '123' > "${GITHUB_APP_CRED_DIR}/fork-id"
    printf '456' > "${GITHUB_APP_CRED_DIR}/upstream-id"
    printf 'fork-id:gh-fork-token,upstream-id:gh-upstream-token' > "${SHARED_DIR}/github-app-token-outputs"
    cat > "${test_dir}/scope-bin/curl" <<'MOCK'
#!/usr/bin/env bash
set -euo pipefail
while [[ $# -gt 0 ]]; do
    if [[ "$1" == --data ]]; then
        printf '%s\n' "$2" >> "${SCOPE_REQUESTS}"
        shift
    fi
    shift
done
printf '{"token":"fake-scoped-token"}\n'
MOCK
    chmod +x "${test_dir}/scope-bin/curl"
    export PATH="${test_dir}/scope-bin:${PATH}"
    refresh_github_tokens > /dev/null
    jq -se '.[0].repositories == ["widgets-fork"] and .[1].repositories == ["widgets"]' "${SCOPE_REQUESTS}" > /dev/null
    : > "${SCOPE_REQUESTS}"
    AGENT_HARNESS=claude-code refresh_github_tokens > /dev/null
    jq -se '. == [{}, {}]' "${SCOPE_REQUESTS}" > /dev/null
)
echo 'PASS: Codex installation tokens are repository-scoped; Claude token behavior is preserved'

write_codex_broker_source "${test_dir}/dptp-github-broker.go"
cp "${repo_root}/hack/dptp-github-broker_test.go" "${test_dir}/dptp-github-broker_test.go"
go test -race "${test_dir}/dptp-github-broker.go" "${test_dir}/dptp-github-broker_test.go"
echo 'PASS: credential broker scopes operations, keeps tokens private, and rejects redirects'
