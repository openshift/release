#!/usr/bin/env bash
set -uo pipefail

_mode="${CONSOLE_FLAKE_AGENT_ENABLED:-false}"
if [[ "${_mode}" != true && "${_mode}" != rehearsal ]]; then
  echo "Console QE Agent disabled; no model call."
  exit 0
fi

export CONSOLE_AGENT_RUNROOT
CONSOLE_AGENT_RUNROOT="$(mktemp -d)"
export CONSOLE_AGENT_METRICS_PATH="${ARTIFACT_DIR}/claude-session-metrics-autodl.json"
trap 'rm -rf "${CONSOLE_AGENT_RUNROOT}"' EXIT

bootstrap_failure() {
  mkdir -p "${ARTIFACT_DIR}"
  printf '> **AI-Generated Content** — Review before use.\n\n# Console e2e failure analysis\n\nInvestigation did not start: %s\n' "$1" \
    > "${ARTIFACT_DIR}/console-flake-analysis.md"
  jq -n --arg job "${JOB_NAME:-}" --arg build "${BUILD_ID:-}" --arg reason "$1" \
    '{schema_version: 1, job_name: $job, build_id: $build, classification: [], verification_status: "skipped", verified_runs: 0, targets: [], patch: null, reason: $reason}' \
    > "${ARTIFACT_DIR}/console-flake-result.json"
  echo "Console QE Agent: $1" >&2
  echo "No verified fix proposal produced."
}

if [[ "${_mode}" == rehearsal ]]; then
  if [[ ! "${JOB_NAME:-}" =~ ^rehearse-([0-9]+)-pull-ci-openshift-console-main-e2e-gcp-console$ ]]; then
    echo "Console QE Agent rehearsal mode is inactive outside the Console main rehearsal."
    exit 0
  fi
  _rehearsal_pr="${BASH_REMATCH[1]}"
  _revision="$(jq -er --arg pr "${_rehearsal_pr}" '
    .refs | select(.org == "openshift" and .repo == "release") |
    .pulls[0] | select((.number | tostring) == $pr) |
    .sha | select(type == "string" and test("^[0-9a-f]{40}$"))
  ' <<< "${JOB_SPEC:-}")" || {
    bootstrap_failure "release rehearsal PR revision is unavailable"
    exit 0
  }
  export CONSOLE_FLAKE_SKILL_REVISION="${_revision}"
else
  _revision="${CONSOLE_FLAKE_SKILL_REVISION:-}"
fi
if [[ ! "${_revision}" =~ ^[0-9a-f]{40}$ ]]; then
  bootstrap_failure "pin CONSOLE_FLAKE_SKILL_REVISION to a merged release commit"
  exit 0
fi

_driver_url="https://raw.githubusercontent.com/openshift/release/${_revision}/ci-operator/config/openshift/console/tools/openshift-console-qe-agent-driver.py"
if ! python3 - "${_driver_url}" "${CONSOLE_AGENT_RUNROOT}/driver.py" <<'PY'
import pathlib
import sys
import urllib.request

with urllib.request.urlopen(sys.argv[1], timeout=30) as response:
    source = response.read(102401)
if len(source) > 102400:
    raise ValueError('pinned Console agent driver exceeds 100 KiB')
compile(source, sys.argv[2], 'exec')
pathlib.Path(sys.argv[2]).write_bytes(source)
PY
then
  bootstrap_failure "pinned Console agent driver is unavailable"
  exit 0
fi

_driver_source="$(cat "${CONSOLE_AGENT_RUNROOT}/driver.py")"
_driver_digest="$(sha256sum "${CONSOLE_AGENT_RUNROOT}/driver.py")"

if ! python3 "${CONSOLE_AGENT_RUNROOT}/driver.py" init; then
  python3 "${CONSOLE_AGENT_RUNROOT}/driver.py" finalize || true
  exit 0
fi

export CONSOLE_AGENT_INVESTIGATION_DEADLINE=$(( $(date +%s) + 3600 ))
if python3 "${CONSOLE_AGENT_RUNROOT}/driver.py" prepare; then
  python3 "${CONSOLE_AGENT_RUNROOT}/driver.py" baseline || true
  _context_digest="$(sha256sum "${CONSOLE_AGENT_RUNROOT}/console-flake-context.json")"
  _selected_digest="$(sha256sum "${CONSOLE_AGENT_RUNROOT}/selected.json")"
  _remaining=$(( CONSOLE_AGENT_INVESTIGATION_DEADLINE - $(date +%s) ))
  if [[ ${_remaining} -gt 0 ]] && command -v claude >/dev/null 2>&1; then
    export CONSOLE_AGENT_CONTEXT="${CONSOLE_AGENT_RUNROOT}/console-flake-context.json"
    export CONSOLE_AGENT_HISTORY="${ARTIFACT_DIR}/console-flake-evidence/history.json"
    export CONSOLE_AGENT_BASELINE="${ARTIFACT_DIR}/console-flake-evidence/baseline.json"
    export CONSOLE_AGENT_EVIDENCE_DIR="${ARTIFACT_DIR}/console-flake-evidence"
    export CONSOLE_AGENT_ARTIFACT_DIR="${ARTIFACT_DIR}"
    export CONSOLE_AGENT_WORKDIR="${CONSOLE_AGENT_RUNROOT}/agent"
    export GIT_CONFIG_COUNT=1 GIT_CONFIG_KEY_0=safe.directory GIT_CONFIG_VALUE_0='*'
    (
      cd "${CONSOLE_AGENT_WORKDIR}" || exit 1
      timeout "${_remaining}s" claude --print --bare --disable-slash-commands \
        --setting-sources "" --strict-mcp-config --no-chrome \
        --permission-mode dontAsk --tools "Bash,Read,Write,Edit,Grep,Glob" \
        --allowedTools "Bash,Read,Write,Edit,Grep,Glob" \
        --model "${CLAUDE_MODEL:-claude-opus-4-6}" --max-budget-usd 5 \
        --no-session-persistence --verbose --output-format stream-json \
        --system-prompt "$(cat "${CONSOLE_AGENT_RUNROOT}/skill.md")" \
        "Read ${CONSOLE_AGENT_CONTEXT}, ${CONSOLE_AGENT_HISTORY}, and ${CONSOLE_AGENT_BASELINE}; investigate the selected original failures. Follow the standalone Console CI skill." \
        > "${CONSOLE_AGENT_RUNROOT}/session.jsonl" 2>&1
    ) || true
  else
    echo "Console QE Agent model unavailable or investigation budget exhausted."
  fi
  if [[ "$(sha256sum "${CONSOLE_AGENT_RUNROOT}/driver.py")" != "${_driver_digest}" ]]; then
    printf '%s\n' "${_driver_source}" > "${CONSOLE_AGENT_RUNROOT}/driver.py"
    echo "Console QE Agent changed verification code; candidate rejected."
    python3 "${CONSOLE_AGENT_RUNROOT}/driver.py" reject || true
  elif [[ "$(sha256sum "${CONSOLE_AGENT_RUNROOT}/console-flake-context.json")" != "${_context_digest}" ||
          "$(sha256sum "${CONSOLE_AGENT_RUNROOT}/selected.json")" != "${_selected_digest}" ]]; then
    echo "Console QE Agent changed original test selection; candidate rejected."
    python3 "${CONSOLE_AGENT_RUNROOT}/driver.py" reject || true
  else
    python3 "${CONSOLE_AGENT_RUNROOT}/driver.py" verify || true
  fi
fi
python3 "${CONSOLE_AGENT_RUNROOT}/driver.py" finalize || true
exit 0
