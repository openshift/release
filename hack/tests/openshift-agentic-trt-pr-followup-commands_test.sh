#!/bin/bash

set -o nounset
set -o errexit
set -o pipefail

SCRIPT_DIR=$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)
COMMAND_SCRIPT="${SCRIPT_DIR}/../../ci-operator/step-registry/openshift/agentic/trt/pr-followup/openshift-agentic-trt-pr-followup-commands.sh"
TEST_ROOT=$(mktemp -d)
trap 'rm -rf "${TEST_ROOT}"' EXIT

fail() {
    echo "FAIL: $*" >&2
    exit 1
}

assert_status() {
    local actual="$1" expected="$2" description="$3"
    [[ "${actual}" == "${expected}" ]] || fail "${description}: expected status ${expected}, got ${actual}"
}

assert_contains() {
    local file="$1" expected="$2"
    if [[ ! -f "${file}" ]] || ! grep -Fq -- "${expected}" "${file}"; then
        [[ ! -f "${file}" ]] || sed -n '1,200p' "${file}" >&2
        fail "expected '${expected}' in ${file}"
    fi
}

assert_not_contains() {
    local file="$1" unexpected="$2"
    if [[ -f "${file}" ]] && grep -Fq -- "${unexpected}" "${file}"; then
        sed -n '1,200p' "${file}" >&2
        fail "did not expect '${unexpected}' in ${file}"
    fi
}

assert_file_absent() {
    local file="$1"
    [[ ! -e "${file}" ]] || fail "did not expect ${file} to exist"
}

make_case() {
    local case_dir="${TEST_ROOT}/${1}"
    mkdir -p "${case_dir}/mock-bin" "${case_dir}/shared" "${case_dir}/work"
    printf '%s\n' 'OCPBUGS-12345' > "${case_dir}/shared/jira-issue-key"

    cat > "${case_dir}/shared/github-app-auth.sh" <<'EOF'
load_github_tokens() { :; }
configure_github_git_credentials() { :; }
EOF

    cat > "${case_dir}/mock-bin/gh" <<'EOF'
#!/bin/bash
set -o nounset
set -o errexit
printf '%s\n' "$*" >> "${MOCK_STATE_DIR}/gh-calls"

if [[ "${1:-} ${2:-}" == "pr list" ]]; then
    [[ "${MOCK_SCENARIO}" == "fallback" ]] || {
        echo "unexpected fallback search" >&2
        exit 90
    }
    printf '%s\n' '[{"number":77}]'
    exit 0
fi

if [[ "${1:-} ${2:-}" != "pr view" ]]; then
    echo "unexpected gh invocation: $*" >&2
    exit 91
fi

number="${3:-}"
if [[ "${MOCK_SCENARIO}" == "missing" ]]; then
    exit 1
fi

head_owner=bot
head_repo=widgets
url="https://github.com/acme/widgets/pull/${number}"
if [[ "${MOCK_SCENARIO}" == "fork_mismatch" ]]; then
    head_owner=someone-else
elif [[ "${MOCK_SCENARIO}" == "upstream_mismatch" ]]; then
    url="https://github.com/other/widgets/pull/${number}"
elif [[ "${MOCK_SCENARIO}" == "case_difference" ]]; then
    head_owner=Bot
    head_repo=Widgets
    url="https://github.com/Acme/Widgets/pull/${number}"
fi

printf '{"number":%s,"state":"OPEN","title":"test","url":"%s","headRefName":"feature-%s","headRefOid":"aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa","headRepository":{"name":"%s"},"headRepositoryOwner":{"login":"%s"}}\n' \
    "${number}" "${url}" "${number}" "${head_repo}" "${head_owner}"
EOF

    cat > "${case_dir}/mock-bin/git" <<'EOF'
#!/bin/bash
set -o nounset
set -o errexit
printf '%s\n' "$*" >> "${MOCK_STATE_DIR}/git-calls"

case "${1:-} ${2:-}" in
    "remote get-url")
        printf '%s\n' 'https://github.com/bot/widgets.git'
        ;;
    "rev-parse --verify")
        if [[ "${MOCK_SCENARIO}" == "sha_mismatch" ]]; then
            printf '%s\n' 'bbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbb'
        else
            printf '%s\n' 'aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa'
        fi
        ;;
    *)
        ;;
esac
EOF
    chmod +x "${case_dir}/mock-bin/gh" "${case_dir}/mock-bin/git"
    printf '%s\n' "${case_dir}"
}

run_case() {
    local scenario="$1" pr_number="$2" override="$3" case_dir status
    case_dir=$(make_case "${scenario}")
    set +o errexit
    PATH="${case_dir}/mock-bin:${PATH}" \
        MOCK_STATE_DIR="${case_dir}" \
        MOCK_SCENARIO="${scenario}" \
        SHARED_DIR="${case_dir}/shared" \
        WORKDIR="${case_dir}/work" \
        UPSTREAM_REPO="acme/widgets" \
        FORK_REPO="bot/widgets" \
        PR_NUMBER="${pr_number}" \
        MULTISTAGE_PARAM_OVERRIDE_PR_NUMBER="${override}" \
        bash "${COMMAND_SCRIPT}" > "${case_dir}/output" 2>&1
    status=$?
    set -o errexit
    printf '%s\t%s\n' "${status}" "${case_dir}"
}

read -r status case_dir < <(run_case explicit 123 "")
assert_status "${status}" 0 "explicit PR selection"
assert_contains "${case_dir}/gh-calls" "pr view 123 --repo acme/widgets"
assert_not_contains "${case_dir}/gh-calls" "pr list"
assert_contains "${case_dir}/git-calls" "fetch --no-tags --no-recurse-submodules fork refs/heads/feature-123"
assert_contains "${case_dir}/git-calls" "checkout --no-recurse-submodules --no-overwrite-ignore -B feature-123 aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa"
[[ $(cat "${case_dir}/shared/pr-number") == 123 ]] || fail "explicit PR number was not persisted"
echo "PASS: explicit PR selection bypasses Jira search"

read -r status case_dir < <(run_case override 111 222)
assert_status "${status}" 0 "Gangway override"
assert_contains "${case_dir}/gh-calls" "pr view 222 --repo acme/widgets"
assert_not_contains "${case_dir}/gh-calls" "pr view 111"
assert_not_contains "${case_dir}/gh-calls" "pr list"
[[ $(cat "${case_dir}/shared/pr-number") == 222 ]] || fail "override PR number was not persisted"
echo "PASS: Gangway override takes precedence"

read -r status case_dir < <(run_case invalid not-a-number "")
[[ "${status}" -ne 0 ]] || fail "invalid explicit PR number unexpectedly succeeded"
assert_file_absent "${case_dir}/gh-calls"
assert_file_absent "${case_dir}/shared/pr-number"
echo "PASS: invalid explicit PR number fails closed"

read -r status case_dir < <(run_case missing 404 "")
[[ "${status}" -ne 0 ]] || fail "missing explicit PR unexpectedly succeeded"
assert_contains "${case_dir}/gh-calls" "pr view 404 --repo acme/widgets"
assert_not_contains "${case_dir}/gh-calls" "pr list"
assert_file_absent "${case_dir}/shared/pr-number"
echo "PASS: missing explicit PR does not fall back"

read -r status case_dir < <(run_case fallback "" "")
assert_status "${status}" 0 "Jira-key fallback"
assert_contains "${case_dir}/gh-calls" "pr list --repo acme/widgets --state open --search OCPBUGS-12345"
assert_contains "${case_dir}/gh-calls" "pr view 77 --repo acme/widgets"
[[ $(cat "${case_dir}/shared/pr-number") == 77 ]] || fail "fallback PR number was not persisted"
echo "PASS: absent PR input preserves Jira-key fallback"

read -r status case_dir < <(run_case fork_mismatch 123 "")
[[ "${status}" -ne 0 ]] || fail "fork mismatch unexpectedly succeeded"
assert_not_contains "${case_dir}/git-calls" "fetch"
assert_file_absent "${case_dir}/shared/pr-number"
echo "PASS: fork mismatch fails before checkout"

read -r status case_dir < <(run_case upstream_mismatch 123 "")
[[ "${status}" -ne 0 ]] || fail "upstream mismatch unexpectedly succeeded"
assert_not_contains "${case_dir}/git-calls" "fetch"
assert_file_absent "${case_dir}/shared/pr-number"
echo "PASS: upstream mismatch fails before checkout"

read -r status case_dir < <(run_case case_difference 123 "")
assert_status "${status}" 0 "case-insensitive repository identity"
assert_contains "${case_dir}/git-calls" "checkout --no-recurse-submodules --no-overwrite-ignore -B feature-123"
echo "PASS: repository identity comparisons ignore case"

read -r status case_dir < <(run_case sha_mismatch 123 "")
[[ "${status}" -ne 0 ]] || fail "head SHA mismatch unexpectedly succeeded"
assert_contains "${case_dir}/git-calls" "fetch --no-tags --no-recurse-submodules fork refs/heads/feature-123"
assert_not_contains "${case_dir}/git-calls" "checkout"
assert_file_absent "${case_dir}/shared/pr-number"
echo "PASS: fetched head mismatch fails before checkout"
