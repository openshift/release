#!/usr/bin/env bash
set -euo pipefail

# Validates that every step-registry command script which runs a *billable* AI
# coding-agent call (Claude or Codex) also emits session-cost metrics, so its
# Vertex/API spend is reported on the CI cost dashboards
# (BigQuery claude_session_metrics table).
#
# Rationale: agents invoked without emitting claude-session-metrics-autodl.json
# spend money invisibly — the dashboards under-report real cost. This check
# fails a presubmit when a new uninstrumented agent job is introduced.
#
# Heuristic:
#   billable  = `agentic-ci run` OR a direct `claude -p/--print`
#   instrumented = the same script emits metrics, OR it hands the raw OTEL off
#                  to a downstream step via ${SHARED_DIR}/claude-otel*, OR it is
#                  explicitly allowlisted below.
#
# Scope note: only Claude spend is metered today — extract_metrics.py reads the
# Claude-specific claude_code.cost.usage OTEL, and Codex cost is not collected.
# `agentic-ci run` can drive either harness but is treated as billable here
# because it is how Claude is metered. If/when Codex cost capture lands, extend
# BILLABLE_RE to catch direct `codex exec/-p/--print` calls too; the script is
# named generically for that reason.

base_dir="${1:-}"

if [[ ! -d "${base_dir}" ]]; then
  echo "Expected a single argument: a path to a directory with release repo layout"
  exit 1
fi

registry_dir="${base_dir}/ci-operator/step-registry"

# Scripts intentionally exempt from the metrics requirement. Keep this list
# short and each entry commented with the reason. Paths are relative to
# ci-operator/step-registry/.
ALLOWLIST=(
  # (none currently)
)

is_allowlisted() {
  local rel="$1" entry
  for entry in ${ALLOWLIST[@]+"${ALLOWLIST[@]}"}; do
    [[ "${rel}" == "${entry}" ]] && return 0
  done
  return 1
}

# A billable AI invocation we can meter today: `agentic-ci run` (Claude via the
# OTEL collector) or a direct `claude -p/--print`. Codex is intentionally out of
# scope until its cost is collected (see the scope note above).
BILLABLE_RE='agentic-ci[[:space:]]+run|claude[[:space:]]+(-p|--print)'

# Evidence that a script emits (or defers emission of) session metrics.
#  - extract_metrics.py / run_claude_metered / emit_session_metrics: the shared
#    OTEL->autodl glue.
#  - claude-session-metrics-autodl.json / claude_session_metrics: an inline
#    autodl emitter (e.g. the obs qe-agent) or an emit-metrics step.
#  - generate_accepted_session_metrics / claude-helpers.sh: other known emitters.
#  - SHARED_DIR}/claude-otel: raw OTEL handed to a downstream step that emits
#    (e.g. the TRT eval init -> solve pattern). ARTIFACT_DIR OTEL alone does NOT
#    count: collecting telemetry without extracting it is the exact bug.
METRICS_RE='extract_metrics\.py|run_claude_metered|emit_session_metrics|claude-session-metrics-autodl\.json|claude_session_metrics|generate_accepted_session_metrics|claude-helpers\.sh|SHARED_DIR\}/claude-otel'

missing=()

while IFS= read -r -d '' script; do
  rel="${script#"${registry_dir}/"}"

  # Normalize the script before matching:
  #  - drop full-line comments so a commented-out example neither trips nor
  #    falsely satisfies the check;
  #  - join shell line-continuations so a billable call split across lines
  #    (e.g. `agentic-ci \`<newline>`run ...`) is still detected. Without this,
  #    a line-by-line grep would miss it and let an uninstrumented job pass.
  code="$(grep -vE '^[[:space:]]*#' "${script}" \
    | awk '{ line=$0; while (line ~ /\\$/) { sub(/\\$/,"",line); if ((getline nxt)<=0) break; line=line " " nxt } print line }' \
    || true)"

  grep -qE "${BILLABLE_RE}" <<<"${code}" || continue

  is_allowlisted "${rel}" && continue

  if ! grep -qE "${METRICS_RE}" <<<"${code}"; then
    missing+=("${rel}")
  fi
done < <(find "${registry_dir}" -name '*-commands.sh' -print0)

if [[ ${#missing[@]} -gt 0 ]]; then
  echo "ERROR: the following step-registry scripts run a billable Claude agent but do not emit session-cost metrics:"
  printf '  - %s\n' "${missing[@]}"
  cat <<'EOF'

Each of these invokes a Claude agent (via `agentic-ci run` or a direct
`claude -p/--print` call) that spends money on Vertex, but produces no
claude-session-metrics-autodl.json, so the spend is invisible on the CI cost
dashboards.

Fix one of these ways:
  1. Run the agent through `agentic-ci run` and, after it exits, emit the autodl:
         python3 /opt/ai-helpers/plugins/prow-agent/scripts/extract_metrics.py \
             "${OTEL_LOG}" "${ARTIFACT_DIR}/claude-session-metrics-autodl.json"
     (collect ${OTEL_LOG} from /tmp/agentic-ci-run.*/claude-otel.jsonl).
  2. For images without agentic-ci, emit claude-session-metrics-autodl.json
     inline from the stream-json "result" record (see the obs qe-agent step).
  3. If the script only collects OTEL and a downstream step emits, write the
     OTEL to ${SHARED_DIR}/claude-otel.jsonl so the handoff is detectable.
  4. If the invocation is genuinely non-billable or exempt, add it to the
     ALLOWLIST in hack/validate-ai-metrics.sh with a comment explaining why.
EOF
  exit 1
fi

echo "OK: all billable AI agent scripts emit session-cost metrics"
