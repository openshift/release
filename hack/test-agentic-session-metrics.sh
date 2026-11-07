#!/usr/bin/env bash
set -euo pipefail

repo_root=$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)
work=$(mktemp -d)
trap 'rm -rf "${work}"' EXIT

export SHARED_DIR="${work}/shared"
export ARTIFACT_DIR="${work}/artifacts"
mkdir -p "${SHARED_DIR}" "${ARTIFACT_DIR}"

# Exercise the actual generator that the init-model Prow step runs.
bash "${repo_root}/ci-operator/step-registry/openshift/agentic/trt/init-model/openshift-agentic-trt-init-model-commands.sh"
# shellcheck source=/dev/null
source "${SHARED_DIR}/trt-telemetry.sh"

# Capture the first harness prompt without exposing it on stdout, and keep a
# later resume/nudge from replacing it.
mkdir -p "${work}/bin" "${work}/workspace/artifacts"
cat > "${work}/bin/agentic-ci" <<'SH'
#!/usr/bin/env bash
exit 0
SH
chmod +x "${work}/bin/agentic-ci"
export PATH="${work}/bin:${PATH}"
export WORKDIR="${work}/workspace"
export AGENT_MODEL="claude-test-model"
export ALLOWED_TOOLS="Read"
agentic_ci "synthetic original prompt" >/dev/null
agentic_ci "synthetic resume prompt" >/dev/null
test "$(cat "${SESSION_PROMPT_FILE}")" = "synthetic original prompt"
python3 -c 'import os, stat, sys; assert stat.S_IMODE(os.stat(sys.argv[1]).st_mode) == 0o600' \
    "${SESSION_PROMPT_FILE}"

cat > "${work}/codex.jsonl" <<'EOF'
{"path":"/v1/metrics","payload":{"resourceMetrics":[{"scopeMetrics":[{"metrics":[{"name":"agentic_ci.codex.cost.usage","sum":{"aggregationTemporality":2,"isMonotonic":true,"dataPoints":[{"asDouble":1.0,"startTimeUnixNano":"100","timeUnixNano":"200","attributes":[{"key":"model","value":{"stringValue":"gpt-main"}}]}]}}]}]}]}}
{"path":"/v1/metrics","payload":{"resourceMetrics":[{"scopeMetrics":[{"metrics":[{"name":"agentic_ci.codex.cost.usage","sum":{"aggregationTemporality":2,"isMonotonic":true,"dataPoints":[{"asDouble":1.5,"startTimeUnixNano":"100","timeUnixNano":"300","attributes":[{"key":"model","value":{"stringValue":"gpt-main"}}]},{"asDouble":0.25,"startTimeUnixNano":"100","timeUnixNano":"300","attributes":[{"key":"model","value":{"stringValue":"gpt-auxiliary"}}]}]}}]}]}]}}
{"path":"/v1/logs","payload":{"resourceLogs":[{"scopeLogs":[{"logRecords":[{"attributes":[{"key":"event.name","value":{"stringValue":"codex.sse_event"}},{"key":"event.kind","value":{"stringValue":"response.completed"}},{"key":"model","value":{"stringValue":"gpt-main"}},{"key":"conversation.id","value":{"stringValue":"session-123"}},{"key":"app.version","value":{"stringValue":"0.164.0"}},{"key":"input_token_count","value":{"intValue":100}},{"key":"cached_token_count","value":{"intValue":80}},{"key":"cache_write_token_count","value":{"intValue":10}},{"key":"output_token_count","value":{"intValue":20}}]}]}]}]}}
EOF

usage=$(codex_otel_usage "${work}/codex.jsonl")
jq -e '
  .cost_from_metric == true
  and .session_id == "session-123"
  and .models["gpt-main"].cost == 1.5
  and .models["gpt-auxiliary"].cost == 0.25
  and .models["gpt-main"].turns == 1
  and .models["gpt-main"].input == 10
  and .models["gpt-main"].cache_read == 80
' <<<"${usage}" >/dev/null

# Stub only the extractor boundary; finalize and emit-metrics remain the real
# consumer path. The stub requires the private initial-prompt handoff.
cat > "${work}/extract-metrics.py" <<'PY'
#!/usr/bin/env python3
import json
import pathlib
import sys

output = pathlib.Path(sys.argv[2])
prompt_path = pathlib.Path(sys.argv[sys.argv.index("--prompt-file") + 1])
prompt = prompt_path.read_text()
if prompt != "synthetic original prompt":
    raise SystemExit(1)
row = {
    "session_id": "session-123",
    "model": "gpt-main",
    "claude_code_version": "0.164.0",
    "prompt": prompt,
    "duration_ms": "1000",
    "num_turns": "1",
    "total_cost_usd": "1.750000",
    "input_tokens": "10",
    "output_tokens": "20",
    "cache_read_input_tokens": "80",
    "cache_creation_input_tokens": "10",
    "cache_hit_rate_pct": "80.0",
}
output.write_text(json.dumps({
    "table_name": "claude_session_metrics",
    "schema": {"session_id": "string"},
    "rows": [row],
}))
PY
chmod +x "${work}/extract-metrics.py"
# shellcheck disable=SC2034 # Consumed by sourced finalize_session_metrics.
EXTRACT_METRICS="${work}/extract-metrics.py"
# shellcheck disable=SC2034 # Consumed by sourced finalize_session_metrics.
OTEL_LOG="${work}/codex.jsonl"
cat > "${SHARED_DIR}/metrics-metadata-solve.json" <<'EOF'
{"agent":"trt-jira-solver","phase":"solve","issue_key":"TEST-1","result":"success","upstream_repo":"example/repo"}
EOF

finalize_session_metrics solve
test -s "${ARTIFACT_DIR}/claude-session-metrics-solve-autodl.json"
test ! -e "${SESSION_PROMPT_FILE}"
jq -e '.session_id == "session-123"' \
    "${SHARED_DIR}/metrics-metadata-solve.json" >/dev/null

emit_artifacts="${work}/emit-artifacts"
mkdir -p "${emit_artifacts}"
emit_log="${work}/emit.log"
ARTIFACT_DIR="${emit_artifacts}" JOB_NAME="synthetic-job" BUILD_ID="123" \
    bash "${repo_root}/ci-operator/step-registry/openshift/agentic/trt/emit-metrics/openshift-agentic-trt-emit-metrics-commands.sh" \
    > "${emit_log}"
grep -Fq "(1 rows)" "${emit_log}"
if grep -Fq 'session-123' "${emit_log}" || grep -Fq '"session_id"' "${emit_log}"; then
    echo "ERROR: emit-metrics disclosed a complete domain row" >&2
    exit 1
fi
jq -e '.rows[0].session_id == "session-123"' \
    "${emit_artifacts}/jira-agent-trt-autodl.json" >/dev/null
jq -e '.rows[0].session_id | type == "string"' \
    "${emit_artifacts}/jira-agent-trt-autodl.json" >/dev/null

# A failed extractor may leave debugging JSON, but finalize must not publish it.
rm -f "${ARTIFACT_DIR}/claude-session-metrics-review-autodl.json"
cat > "${work}/failing-extractor.py" <<'PY'
#!/usr/bin/env python3
import pathlib
import sys
pathlib.Path(sys.argv[2]).write_text('{"rows":[{"input_tokens":"1"}]}')
raise SystemExit(1)
PY
# shellcheck disable=SC2034 # Consumed by sourced finalize_session_metrics.
EXTRACT_METRICS="${work}/failing-extractor.py"
finalize_session_metrics review
test ! -e "${ARTIFACT_DIR}/claude-session-metrics-review-autodl.json"

# A success-exit extractor with malformed JSON must remain best-effort: no
# invalid artifact, no task abort, and no retained private prompt handoff.
cat > "${work}/malformed-extractor.py" <<'PY'
#!/usr/bin/env python3
import pathlib
import sys
pathlib.Path(sys.argv[2]).write_text("not-json", encoding="utf-8")
PY
SESSION_PROMPT_FILE=$(mktemp "${TMPDIR:-/tmp}/trt-session-initial-prompt.XXXXXX")
printf '%s' "synthetic malformed prompt" > "${SESSION_PROMPT_FILE}"
EXTRACT_METRICS="${work}/malformed-extractor.py"
finalize_session_metrics review
test ! -e "${ARTIFACT_DIR}/claude-session-metrics-review-autodl.json"
test ! -e "${SESSION_PROMPT_FILE}"

# Structurally valid JSON with a non-string session identity is not a valid
# autodl row and must follow the same cleanup path.
cat > "${work}/wrong-type-extractor.py" <<'PY'
#!/usr/bin/env python3
import json
import pathlib
import sys
payload = {
    "table_name": "claude_session_metrics",
    "schema": {"session_id": "string"},
    "rows": [{"session_id": 123}],
}
pathlib.Path(sys.argv[2]).write_text(json.dumps(payload), encoding="utf-8")
PY
SESSION_PROMPT_FILE=$(mktemp "${TMPDIR:-/tmp}/trt-session-initial-prompt.XXXXXX")
printf '%s' "synthetic wrong-type prompt" > "${SESSION_PROMPT_FILE}"
EXTRACT_METRICS="${work}/wrong-type-extractor.py"
finalize_session_metrics review
test ! -e "${ARTIFACT_DIR}/claude-session-metrics-review-autodl.json"
test ! -e "${SESSION_PROMPT_FILE}"

# An unreadable extractor result is also discarded without changing the task
# result or retaining the prompt handoff.
cat > "${work}/unreadable-extractor.py" <<'PY'
#!/usr/bin/env python3
import os
import pathlib
import sys
output = pathlib.Path(sys.argv[2])
output.write_text(
    '{"table_name":"claude_session_metrics",'
    '"schema":{"session_id":"string"},'
    '"rows":[{"session_id":"synthetic-unreadable-session"}]}',
    encoding="utf-8",
)
os.chmod(output, 0)
PY
SESSION_PROMPT_FILE=$(mktemp "${TMPDIR:-/tmp}/trt-session-initial-prompt.XXXXXX")
printf '%s' "synthetic unreadable prompt" > "${SESSION_PROMPT_FILE}"
# shellcheck disable=SC2034 # Consumed by sourced finalize_session_metrics.
EXTRACT_METRICS="${work}/unreadable-extractor.py"
finalize_session_metrics review
test ! -e "${ARTIFACT_DIR}/claude-session-metrics-review-autodl.json"
test ! -e "${SESSION_PROMPT_FILE}"

# Early skip paths must discard a captured prompt too.
SESSION_PROMPT_FILE=$(mktemp "${TMPDIR:-/tmp}/trt-session-initial-prompt.XXXXXX")
printf '%s' "synthetic skipped prompt" > "${SESSION_PROMPT_FILE}"
# shellcheck disable=SC2034 # Consumed by sourced finalize_session_metrics.
OTEL_LOG="${work}/missing-otel.jsonl"
finalize_session_metrics review
test ! -e "${SESSION_PROMPT_FILE}"

echo "PASS: agentic session metrics extraction and dashboard join path"
