#!/bin/bash
# Behavioral tests for the report collection of the openshift-claude-bulk-triage
# step: the copy_reports exit trap copies the markdown report and renders
# triage-summary-<view>.html from the final report.
#
# The real step script runs with its hard-coded /tmp, /opt/ai-helpers and
# /home/claude paths redirected into a scratch directory and with stubbed
# external commands: no Claude session, gcloud download, JIRA or Sippy access.
#
# Requirements: bash, python3, jq, tar, gzip and coreutils timeout (all present
# in the claude-ai-helpers image). No presubmit runs this test: the image of the
# step-registry shellcheck job has neither python3 nor jq.
#
# Usage: hack/tests/openshift-claude-bulk-triage-commands_test.sh [MARKDOWN_TO_HTML]
#
# MARKDOWN_TO_HTML is the ai-helpers plugins/prow-agent/scripts/markdown_to_html.py
# helper; it defaults to the copy in the claude-ai-helpers image. When it is not
# available, the end-to-end case through the real helper is skipped and the
# caller contract is still checked with a stub helper.

set -o nounset
set -o errexit
set -o pipefail

SCRIPT_DIR=$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)
REPO_ROOT=$(cd "${SCRIPT_DIR}/../.." && pwd)
COMMAND_SCRIPT="${REPO_ROOT}/ci-operator/step-registry/openshift/claude/bulk-triage/openshift-claude-bulk-triage-commands.sh"
PROW_CONFIG="${REPO_ROOT}/core-services/prow/02_config/_config.yaml"
REAL_CONVERTER="${1:-/opt/ai-helpers/plugins/prow-agent/scripts/markdown_to_html.py}"

VIEW="5.1-main"
REPORT="triage-duty-report-${VIEW}.md"
SUMMARY="triage-summary-${VIEW}.html"
USAGE_HEADING="## Session usage"

for tool in python3 jq tar gzip timeout; do
    if ! command -v "${tool}" >/dev/null; then
        echo "ERROR: ${tool} is required to run this test." >&2
        exit 2
    fi
done

TEST_ROOT=$(mktemp -d)
trap 'rm -rf "${TEST_ROOT}"' EXIT

FAILURES=0
CASE_NAME=""
CASE_DIR=""
RC=0

fail() {
    echo "FAIL: ${CASE_NAME}: $*" >&2
    FAILURES=$((FAILURES + 1))
    if [[ -f "${CASE_DIR}/output.log" ]]; then
        sed 's/^/    | /' "${CASE_DIR}/output.log" >&2
    fi
}

assert_eq() {
    local expected="$1" actual="$2" what="$3"
    [[ "${expected}" == "${actual}" ]] || fail "${what}: expected '${expected}', got '${actual}'"
}

assert_file() {
    [[ -s "$1" ]] || fail "expected non-empty file $1"
}

assert_no_file() {
    [[ ! -e "$1" ]] || fail "did not expect $1"
}

assert_contains() {
    local file="$1" expected="$2"
    grep -Fq -- "${expected}" "${file}" 2>/dev/null || fail "expected '${expected}' in ${file##*/}"
}

assert_not_contains() {
    local file="$1" unexpected="$2"
    if [[ ! -f "${file}" ]]; then
        fail "expected file ${file##*/}"
    elif grep -Fq -- "${unexpected}" "${file}"; then
        fail "did not expect '${unexpected}' in ${file##*/}"
    fi
}

# --- Shared fixtures ---------------------------------------------------------

# The step only installs gcloud; an archive with a no-op installer stands in for the SDK download.
mkdir -p "${TEST_ROOT}/gcloud/google-cloud-sdk"
printf '#!/bin/sh\nexit 0\n' > "${TEST_ROOT}/gcloud/google-cloud-sdk/install.sh"
chmod +x "${TEST_ROOT}/gcloud/google-cloud-sdk/install.sh"
tar -czf "${TEST_ROOT}/gcloud.tar.gz" -C "${TEST_ROOT}/gcloud" google-cloud-sdk

mkdir -p "${TEST_ROOT}/bin"
cat > "${TEST_ROOT}/bin/curl" <<'EOF'
#!/bin/bash
for arg in "$@"; do
    if [[ "${arg}" == *google-cloud-cli-linux-x86_64.tar.gz ]]; then
        cat "${STUB_GCLOUD_ARCHIVE}"
        exit 0
    fi
done
echo "curl stub: unexpected request: $*" >&2
exit 22
EOF

# agentic-ci stub. STUB_AGENT_MODE selects what the "session" leaves behind:
#   report  - writes STUB_REPORT_SOURCE as the report
#   empty   - writes an empty report
#   none    - writes no report
#   term    - writes a partial report, then sends SIGTERM to the step script
# Every invocation also leaves OTEL output where the step collects it.
cat > "${TEST_ROOT}/bin/agentic-ci" <<'EOF'
#!/bin/bash
set -o nounset -o errexit
printf '%s\n' "$*" >> "${STUB_AGENT_LOG}"
workdir=""
prev=""
for arg in "$@"; do
    [[ "${prev}" == "--workdir" ]] && workdir="${arg}"
    prev="${arg}"
done
mkdir -p "${STUB_TMP}/agentic-ci-run.$$"
echo '{"stub": true}' > "${STUB_TMP}/agentic-ci-run.$$/claude-otel.jsonl"
case "${STUB_AGENT_MODE}" in
    report) cp "${STUB_REPORT_SOURCE}" "${workdir}/${STUB_REPORT_NAME}" ;;
    empty) : > "${workdir}/${STUB_REPORT_NAME}" ;;
    none) ;;
    term)
        printf '# Partial report\n\nInterrupted analysis.\n' > "${workdir}/${STUB_REPORT_NAME}"
        # Parent is timeout(1); its parent is the step script.
        script_pid=$(awk '{print $4}' "/proc/${PPID}/stat")
        kill -TERM "${script_pid}"
        ;;
    *) echo "agentic-ci stub: unknown mode ${STUB_AGENT_MODE}" >&2; exit 1 ;;
esac
EOF
chmod +x "${TEST_ROOT}/bin/curl" "${TEST_ROOT}/bin/agentic-ci"

cat > "${TEST_ROOT}/extract_metrics.py" <<'EOF'
import json, sys
row = {"model": "claude-opus-5", "num_turns": 12, "total_tool_calls": 34, "num_subagents": 2,
       "input_tokens": 1000, "output_tokens": 200, "cache_read_input_tokens": 300,
       "cache_creation_input_tokens": 40, "cache_hit_rate_pct": 23.1, "total_cost_usd": 1.5,
       "duration_ms": "600000"}
with open(sys.argv[2], "w") as f:
    json.dump({"rows": [row]}, f)
EOF

# Stub helper: records each invocation with a snapshot of its input, then writes
# a page or fails with STUB_CONVERTER_EXIT.
cat > "${TEST_ROOT}/converter_stub.py" <<'EOF'
import json, os, sys
args = sys.argv[1:]
src, out = args[-2], args[-1]
with open(src, encoding="utf-8") as f:
    snapshot = f.read()
with open(os.environ["STUB_CONVERTER_LOG"], "a") as f:
    f.write(json.dumps({"args": args, "input": snapshot}) + "\n")
code = int(os.environ.get("STUB_CONVERTER_EXIT", "0"))
if code == 0:
    with open(out, "w") as f:
        f.write("<html>stub</html>\n")
sys.exit(code)
EOF

printf '# Triage duty report %s\n\nAll buckets triaged.\n' "${VIEW}" > "${TEST_ROOT}/report.md"
cat > "${TEST_ROOT}/hostile-report.md" <<'EOF'
# Triage duty report <script>alert(1)</script>

| Regression | Run |
|---|---|
| <img src=x onerror=alert(2)> | [run](https://prow.ci.openshift.org/view/gs/x"onclick="alert(3)) |

[bad](javascript:alert(4))

See https://prow.ci.openshift.org/view/`x" autofocus onfocus="alert(5)" y="` for details.
EOF

# --- Case runner ---------------------------------------------------------------

# Every hard-coded absolute path in the step must be one the harness redirects;
# a new one would escape the scratch directory, so the test refuses to run.
unhandled_paths=$(grep -noE '/(tmp|opt|home)\b[^[:space:]"]*' "${COMMAND_SCRIPT}" \
    | grep -vE ':(/tmp|/tmp/.*|/opt/ai-helpers.*|/home/claude/\.claude.*)$' || true)
if [[ -n "${unhandled_paths}" ]]; then
    echo "ERROR: the step uses absolute paths this harness does not redirect:" >&2
    echo "${unhandled_paths}" >&2
    exit 1
fi

# run_case NAME AGENT_MODE CONVERTER [REPORT_SOURCE]
# CONVERTER: stub, real, or missing. CASE_VIEW overrides TRIAGE_VIEW.
# Leaves RC, CASE_DIR, ART, CONV_LOG set.
run_case() {
    CASE_NAME="$1"
    local agent_mode="$2" converter="$3" report_source="${4:-${TEST_ROOT}/report.md}"
    local view="${CASE_VIEW:-${VIEW}}"
    CASE_DIR="${TEST_ROOT}/case-${CASE_NAME}"
    ART="${CASE_DIR}/artifacts"
    CONV_LOG="${CASE_DIR}/converter.jsonl"
    local scripts="${CASE_DIR}/opt/ai-helpers/plugins/prow-agent/scripts"
    mkdir -p "${CASE_DIR}/tmp" "${CASE_DIR}/home" "${CASE_DIR}/shared" "${ART}" "${scripts}"
    : > "${CONV_LOG}"
    cp "${TEST_ROOT}/extract_metrics.py" "${scripts}/extract_metrics.py"
    case "${converter}" in
        stub) cp "${TEST_ROOT}/converter_stub.py" "${scripts}/markdown_to_html.py" ;;
        real) cp "${REAL_CONVERTER}" "${scripts}/markdown_to_html.py" ;;
        missing) ;;
    esac
    # Placeholders first, so a scratch path under /tmp is not rewritten again.
    sed -e "s#/opt/ai-helpers#@OPT@#g" \
        -e "s#/home/claude/\.claude#@HOME@#g" \
        -e "s#/tmp/#@TMP@/#g" \
        -e "s#-C /tmp\$#-C @TMP@#" \
        "${COMMAND_SCRIPT}" \
        | sed -e "s#@OPT@#${CASE_DIR}/opt/ai-helpers#g" \
            -e "s#@HOME@#${CASE_DIR}/home/claude/.claude#g" \
            -e "s#@TMP@#${CASE_DIR}/tmp#g" > "${CASE_DIR}/commands.sh"
    if [[ -n "${PRE_RUN_HOOK:-}" ]]; then
        "${PRE_RUN_HOOK}"
    fi
    RC=0
    env -i \
        PATH="${TEST_ROOT}/bin:${PATH}" \
        HOME="${CASE_DIR}/home" \
        ARTIFACT_DIR="${ART}" \
        SHARED_DIR="${CASE_DIR}/shared" \
        TRIAGE_VIEW="${view}" \
        TRIAGE_COMPONENTS="all" \
        TRIAGE_EXISTING_ONLY="true" \
        CLAUDE_MODEL="claude-opus-5" \
        JIRA_CLIENT_ID_PATH="${CASE_DIR}/no-jira-id" \
        JIRA_CLIENT_SECRET_PATH="${CASE_DIR}/no-jira-secret" \
        DPCR_TOKEN_PATH="${CASE_DIR}/no-dpcr-token" \
        STUB_GCLOUD_ARCHIVE="${TEST_ROOT}/gcloud.tar.gz" \
        STUB_AGENT_LOG="${CASE_DIR}/agentic-ci.log" \
        STUB_AGENT_MODE="${agent_mode}" \
        STUB_REPORT_NAME="triage-duty-report-${view}.md" \
        STUB_REPORT_SOURCE="${report_source}" \
        STUB_TMP="${CASE_DIR}/tmp" \
        STUB_CONVERTER_LOG="${CONV_LOG}" \
        STUB_CONVERTER_EXIT="${STUB_CONVERTER_EXIT:-0}" \
        bash "${CASE_DIR}/commands.sh" > "${CASE_DIR}/output.log" 2>&1 || RC=$?
}

converter_calls() {
    jq -s 'length' "${CONV_LOG}"
}

# converter_input N: the report content the helper received on call N (0-based).
converter_input() {
    jq -rs --argjson n "$1" '.[$n].input' "${CONV_LOG}"
}

# --- Cases ---------------------------------------------------------------------

# Normal run: the HTML is rendered next to the markdown, from the final report.
run_case normal report stub
assert_eq 0 "${RC}" "exit status"
assert_file "${ART}/${REPORT}"
assert_file "${ART}/${SUMMARY}"
assert_contains "${ART}/${REPORT}" "${USAGE_HEADING}"
assert_eq 1 "$(converter_calls)" "helper calls"
assert_eq "$(cat "${ART}/${REPORT}")" "$(converter_input 0)" "helper input is the final report"
# --title <report name> <workdir>/<report> <ARTIFACT_DIR>/<summary>
helper_args=$(jq -c '.args | .[0:2] + [(.[2] | split("/") | last), (.[3] | ltrimstr($art + "/"))]' \
    --arg art "${ART}" "${CONV_LOG}")
assert_eq "[\"--title\",\"${REPORT}\",\"${REPORT}\",\"${SUMMARY}\"]" "${helper_args}" "helper arguments"
assert_contains "${CASE_DIR}/output.log" "Existing-only: true"
assert_contains "${CASE_DIR}/output.log" "Model: claude-opus-5"
assert_contains "${CASE_DIR}/agentic-ci.log" "--model claude-opus-5"
assert_contains "${CASE_DIR}/agentic-ci.log" "run in --existing-only mode"
assert_contains "${CASE_DIR}/agentic-ci.log" "Do NOT create any new JIRA issue"
assert_file "${ART}/junit_claude-ci.xml"
assert_not_contains "${ART}/junit_claude-ci.xml" "<failure"
NORMAL_SUMMARY_BASENAME=$(cd "${ART}" && find . -maxdepth 1 -name "*.html" -printf "%f\n")

# SIGTERM during the session: once the foreground session command returns, the
# TERM trap collects and renders the partial report; the script then carries on
# and the final exit renders it again with the session usage.
run_case term term stub
assert_eq 0 "${RC}" "exit status"
assert_eq 2 "$(converter_calls)" "helper calls"
first_input=$(converter_input 0)
[[ "${first_input}" == *"Interrupted analysis."* && "${first_input}" != *"${USAGE_HEADING}"* ]] \
    || fail "first render should see the partial report without session usage"
[[ "$(converter_input 1)" == *"${USAGE_HEADING}"* ]] || fail "final render should include session usage"
assert_file "${ART}/${SUMMARY}"

# The step fails after the report exists (here: the junit cannot be written).
# The exit status is kept and the HTML still comes from the final report.
block_junit() { mkdir -p "${ART}/junit_claude-ci.xml"; }
PRE_RUN_HOOK=block_junit run_case errexit report stub
assert_eq 1 "${RC}" "exit status"
assert_file "${ART}/${SUMMARY}"
assert_eq 1 "$(converter_calls)" "helper calls"
[[ "$(converter_input 0)" == *"${USAGE_HEADING}"* ]] || fail "render should include session usage"

# No report: the step keeps failing as before and nothing is rendered.
run_case missing-report none stub
assert_eq 1 "${RC}" "exit status"
assert_eq 0 "$(converter_calls)" "helper calls"
assert_no_file "${ART}/${SUMMARY}"
assert_no_file "${ART}/${REPORT}"
assert_contains "${ART}/junit_claude-ci.xml" "No report generated"
assert_contains "${CASE_DIR}/output.log" "No markdown report to render; skipping ${SUMMARY}."

# Empty report: treated like no report.
run_case empty-report empty stub
assert_eq 1 "${RC}" "exit status"
assert_eq 0 "$(converter_calls)" "helper calls"
assert_no_file "${ART}/${SUMMARY}"

# Older image without the helper: warn, keep the markdown, keep the exit status.
run_case missing-helper report missing
assert_eq 0 "${RC}" "exit status"
assert_file "${ART}/${REPORT}"
assert_contains "${ART}/${REPORT}" "${USAGE_HEADING}"
assert_no_file "${ART}/${SUMMARY}"
assert_contains "${CASE_DIR}/output.log" "markdown_to_html.py is not in this image; skipping ${SUMMARY}."

# Helper failure: warn, keep the markdown, keep the exit status.
STUB_CONVERTER_EXIT=3 run_case helper-failure report stub
assert_eq 0 "${RC}" "exit status"
assert_file "${ART}/${REPORT}"
assert_no_file "${ART}/${SUMMARY}"
assert_contains "${CASE_DIR}/output.log" "Warning: could not render ${SUMMARY}."

# Helper failure on top of a failing step: the step's exit status wins.
STUB_CONVERTER_EXIT=3 PRE_RUN_HOOK=block_junit run_case helper-failure-errexit report stub
assert_eq 1 "${RC}" "exit status"
assert_file "${ART}/${REPORT}"
assert_contains "${CASE_DIR}/output.log" "Warning: could not render ${SUMMARY}."

# A view name the html lens could not show safely as an artifact name: no HTML.
unsafe_view='5.1-main" onmouseover="alert(1)'
CASE_VIEW="${unsafe_view}" run_case unsafe-view report stub
assert_eq 0 "${RC}" "exit status"
assert_file "${ART}/triage-duty-report-${unsafe_view}.md"
assert_eq 0 "$(converter_calls)" "helper calls"
assert_eq "" "$(find "${ART}" -maxdepth 1 -name "*.html")" "HTML artifacts"
assert_contains "${CASE_DIR}/output.log" "skipping the HTML report."

# End to end through the real helper, including hostile report content.
if [[ -f "${REAL_CONVERTER}" ]]; then
    run_case real-helper report real "${TEST_ROOT}/hostile-report.md"
    assert_eq 0 "${RC}" "exit status"
    html="${ART}/${SUMMARY}"
    assert_file "${html}"
    assert_contains "${html}" "<title>${REPORT}</title>"
    assert_contains "${html}" "<h2>Session usage</h2>"
    assert_contains "${html}" "<td>claude-opus-5</td>"
    assert_contains "${html}" 'href="https://prow.ci.openshift.org/view/gs/x%22onclick=%22alert(3"'
    assert_not_contains "${html}" 'href="javascript:'
    # Parse the page as a browser would, both opened directly and as the Prow
    # html lens shows it: the lens puts the page into an iframe srcdoc attribute
    # (replacing only '"'), so character references are decoded once more.
    # No element or attribute may come from the report, and its text must read
    # the same in both views.
    markup_check=$(python3 - "${html}" <<'PYEOF'
import html
import sys
from html.parser import HTMLParser

bad = []


class Check(HTMLParser):
    def __init__(self, view):
        super().__init__(convert_charrefs=True)
        self.view = view
        self.text = []

    def handle_starttag(self, tag, attrs):
        if tag in ("script", "img", "iframe", "svg", "object", "embed"):
            bad.append("%s: <%s>" % (self.view, tag))
        for key, value in attrs:
            if key.startswith("on") or (key == "href" and not value.startswith(("https://", "http://"))):
                bad.append("%s: %s=%r on <%s>" % (self.view, key, value, tag))

    def handle_data(self, data):
        self.text.append(data)


page = open(sys.argv[1], encoding="utf-8").read()
for view, document in (("direct", page), ("lens", html.unescape(page.replace('"', "&quot;")))):
    check = Check(view)
    check.feed(document)
    check.close()
    text = "".join(check.text)
    for expected in ("<script>alert(1)</script>", "<img src=x onerror=alert(2)>"):
        if expected not in text:
            bad.append("%s: text %r not shown" % (view, expected))
print("; ".join(bad))
PYEOF
    )
    [[ -z "${markup_check}" ]] || fail "unsafe markup in rendered HTML: ${markup_check}"
else
    echo "SKIP: real-helper: ${REAL_CONVERTER} not found (pass the ai-helpers markdown_to_html.py path to run it)"
fi

# The rendered basename must be shown by the Prow html lens: deck matches each
# required_files regex (Go regexp, unanchored) against artifact paths. The
# pattern is plain RE2 syntax, so Python's re.search has the same semantics.
CASE_NAME="prow-html-lens"
CASE_DIR="${TEST_ROOT}/case-${CASE_NAME}"
lens_check=$(python3 - "${PROW_CONFIG}" "${NORMAL_SUMMARY_BASENAME}" "${REPORT}" <<'EOF'
import re, sys

config, summary, report = sys.argv[1:4]
lines = open(config, encoding="utf-8").read().splitlines()
required, in_html, in_required = [], False, False
for line in lines:
    stripped = line.strip()
    if stripped == "name: html":
        in_html = True
        continue
    if in_html:
        if stripped.startswith("- lens:") or (line and not line.startswith("      ")):
            break
        if stripped == "required_files:":
            in_required = True
            continue
        if in_required:
            if stripped.startswith("- "):
                required.append(stripped[2:].strip().strip("'\""))
            else:
                in_required = False
if not required:
    sys.exit("could not find the html lens required_files in " + config)
path = "artifacts/bulk-triage-regressions/openshift-claude-bulk-triage/artifacts/"
for pattern in required:
    if not re.search(pattern, path + summary):
        sys.exit("%s does not match html lens pattern %s" % (summary, pattern))
if all(re.search(p, path + report) for p in required):
    sys.exit("sanity check failed: %s should not match the html lens" % report)
print("ok: %s matches %s" % (summary, " AND ".join(required)))
EOF
) || fail "${lens_check}"
echo "${lens_check}"
assert_eq "${SUMMARY}" "${NORMAL_SUMMARY_BASENAME}" "rendered artifact name"

if [[ "${FAILURES}" -gt 0 ]]; then
    echo "${FAILURES} check(s) failed."
    exit 1
fi
echo "All openshift-claude-bulk-triage report collection checks passed."
