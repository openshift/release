#!/bin/bash
set -euo pipefail

repo_dir=$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)
script="${repo_dir}/ci-operator/step-registry/redhat-developer/rhdh-plugin-export-overlays/ocp/helm/osl-rc/redhat-developer-rhdh-plugin-export-overlays-ocp-helm-osl-rc-commands.sh"
source <(sed -n \
    -e '/^catalog_diagnostic_state() {/,/^}/p' \
    -e '/^subscription_diagnostic_summary() {/,/^}/p' \
    -e '/^worker_mcp_diagnostic_summary() {/,/^}/p' \
    -e '/^sanitize_playwright_counts() {/,/^}/p' \
    -e '/^publish_playwright_counts() {/,/^}/p' \
    -e '/^run_playwright() {/,/^}/p' \
    "${script}")

for function in catalog_diagnostic_state subscription_diagnostic_summary worker_mcp_diagnostic_summary sanitize_playwright_counts publish_playwright_counts run_playwright; do
    declare -F "${function}" >/dev/null || {
        echo "FAIL: production function ${function} is missing" >&2
        exit 1
    }
done

assert_equal() {
    local expected="$1"
    local actual="$2"
    local description="$3"
    [[ "${actual}" == "${expected}" ]] || {
        echo "FAIL: ${description}: expected [${expected}], got [${actual}]" >&2
        exit 1
    }
}

catalog='{"spec":{"image":"registry.example/private@sha256:secret"},"status":{"connectionState":{"lastObservedState":"READY","message":"token=CATALOG_SECRET"}}}'
assert_equal READY "$(catalog_diagnostic_state "${catalog}")" 'catalog diagnostics allowlist only the state'
assert_equal unknown "$(catalog_diagnostic_state '{"status":{"connectionState":{"lastObservedState":"READY token=CATALOG_SECRET"}}}')" 'unexpected catalog states are hidden'
assert_equal unknown "$(catalog_diagnostic_state '')" 'missing catalog data is hidden'

subscription='{"status":{"conditions":[{"type":"ResolutionFailed","status":"True","message":"token=SUBSCRIPTION_SECRET"},{"type":"UntrustedCondition","status":"True","message":"token=OTHER_SECRET"}]}}'
assert_equal ResolutionFailed=True "$(subscription_diagnostic_summary "${subscription}")" 'subscription diagnostics allowlist condition type and status'
assert_equal 'status unavailable' "$(subscription_diagnostic_summary '')" 'missing subscription data is hidden'

mcp='{"status":{"configuration":{"name":"rendered-secret-config"},"updatedMachineCount":4,"readyMachineCount":3,"unavailableMachineCount":1,"degradedMachineCount":0,"conditions":[{"type":"Degraded","status":"False","message":"token=MCP_SECRET"}]}}'
assert_equal 'updated=4 ready=3 unavailable=1 degraded=0' "$(worker_mcp_diagnostic_summary "${mcp}")" 'worker diagnostics retain only numeric rollout counts'
assert_equal 'worker status unavailable' "$(worker_mcp_diagnostic_summary '')" 'missing worker data is hidden'

results='{"stats":{"expected":29,"unexpected":0,"flaky":0,"skipped":2},"suites":[{"title":"token=REPORT_SECRET","url":"https://example.invalid/session-secret"}],"attachments":["secret"]}'
assert_equal '{"expected":29,"unexpected":0,"flaky":0,"skipped":2}' "$(sanitize_playwright_counts <(printf '%s' "${results}"))" 'Playwright artifacts contain only aggregate counts'
assert_equal '{"expected":null,"unexpected":0,"flaky":0,"skipped":2}' "$(sanitize_playwright_counts <(printf '%s' '{"stats":{"expected":"token=REPORT_SECRET","unexpected":0,"flaky":0,"skipped":2},"url":"https://example.invalid/session-secret"}'))" 'non-numeric report counts do not pass through'

test_dir=$(mktemp -d)
trap 'rm -rf "${test_dir}"' EXIT
ARTIFACT_DIR="${test_dir}/artifacts"
export ARTIFACT_DIR
printf '%s' "${results}" > "${test_dir}/results.json"
assert_equal '{"expected":29,"unexpected":0,"flaky":0,"skipped":2}' "$(publish_playwright_counts "${test_dir}/results.json")" 'published Playwright summary is sanitized'
assert_equal '{"expected":29,"unexpected":0,"flaky":0,"skipped":2}' "$(cat "${ARTIFACT_DIR}/osl-rc-test-counts.json")" 'Prow artifact contains only aggregate counts'

cat > "${test_dir}/run-e2e.sh" <<'EOF'
#!/bin/bash
echo 'token=RUNNER_SECRET https://example.invalid/session-secret'
echo 'password=RUNNER_SECRET' >&2
exit 17
EOF
chmod +x "${test_dir}/run-e2e.sh"
WORKDIR="${test_dir}"
export WORKDIR
set +e
runner_output=$(cd "${test_dir}" && run_playwright 2>&1)
runner_status=$?
set -e
assert_equal '' "${runner_output}" 'raw Playwright output is not streamed to Prow logs'
assert_equal 17 "${runner_status}" 'Playwright failure status is preserved'
[[ ! -e "${test_dir}/playwright.log" ]] || {
    echo 'FAIL: raw Playwright output was retained' >&2
    exit 1
}

echo 'PASS: diagnostics and Playwright artifacts expose only allowlisted status and counts'
