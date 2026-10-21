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
_spyglass_written=false

write_spyglass_link() {
  local analysis="${ARTIFACT_DIR}/console-flake-analysis.md"
  local result="${ARTIFACT_DIR}/console-flake-result.json"
  local patch="${ARTIFACT_DIR}/console-flake-fix.patch"
  local report="${ARTIFACT_DIR}/custom-link-console-flake.html"
  [[ -f "${analysis}" || -f "${result}" ]] || return 0

  local job="${JOB_NAME:-}" build="${BUILD_ID:-}" pull="${PULL_NUMBER:-}"
  local repository="" base=""
  if [[ "${job}" =~ ^rehearse-([0-9]+)-pull-ci-openshift-console-main-e2e-gcp-console$ ]]; then
    repository=openshift_release
    pull="${BASH_REMATCH[1]}"
  elif [[ "${job}" == pull-ci-openshift-console-main-e2e-gcp-console ]]; then
    repository=openshift_console
    if [[ ! "${pull}" =~ ^[0-9]+$ ]]; then
      pull="$(jq -er '.refs.pulls[0].number | tostring | select(test("^[0-9]+$"))' <<< "${JOB_SPEC:-}" 2>/dev/null)" || pull=""
    fi
  fi
  if [[ -n "${repository}" && "${pull}" =~ ^[0-9]+$ && "${build}" =~ ^[0-9]+$ ]]; then
    base="https://gcs.ci.openshift.org/gcs/test-platform-results-public/pr-logs/pull/${repository}/${pull}/${job}/${build}/artifacts/e2e-gcp-console/openshift-console-qe-agent/artifacts"
  fi

  {
    printf '%s\n' '<!doctype html>' '<html lang="en"><head><meta charset="utf-8"><title>Console QE Agent results</title><style>body { color: black; background: white; font-family: sans-serif; }</style></head><body>'
    printf '%s\n' '<p>Agent output is available for this job. Review the analysis and verification status before applying any proposed change.</p>'
    if [[ -n "${base}" ]]; then
      printf '%s\n' '<ul>'
      [[ -f "${analysis}" ]] && printf '<li><a href="%s/console-flake-analysis.md" target="_blank" rel="noopener noreferrer">Root cause analysis</a></li>\n' "${base}"
      [[ -f "${result}" ]] && printf '<li><a href="%s/console-flake-result.json" target="_blank" rel="noopener noreferrer">Result and verification status</a></li>\n' "${base}"
      [[ -s "${patch}" ]] && printf '<li><a href="%s/console-flake-fix.patch" target="_blank" rel="noopener noreferrer">Candidate patch</a></li>\n' "${base}"
      printf '<li><a href="%s/" target="_blank" rel="noopener noreferrer">All agent artifacts</a></li>\n' "${base}"
      printf '%s\n' '</ul>'
    else
      printf '%s\n' '<p>Open the openshift-console-qe-agent artifacts folder for console-flake-analysis.md and console-flake-result.json.</p>'
    fi
    printf '%s\n' '</body></html>'
  } > "${report}" || return 1
  _spyglass_written=true
}

cleanup() {
  if [[ "${_spyglass_written}" != true ]]; then
    write_spyglass_link || true
  fi
  rm -rf "${CONSOLE_AGENT_RUNROOT}"
}
trap cleanup EXIT

bootstrap_failure() {
  mkdir -p "${ARTIFACT_DIR}"
  printf '> **AI-Generated Content** — Review before use.\n\n# Console e2e failure analysis\n\nInvestigation did not start: %s\n' "$1" \
    > "${ARTIFACT_DIR}/console-flake-analysis.md"
  jq -n --arg job "${JOB_NAME:-}" --arg build "${BUILD_ID:-}" --arg reason "$1" \
    '{schema_version: 1, job_name: $job, build_id: $build, classification: [], verification_status: "skipped", verified_runs: 0, targets: [], patch: null, reason: $reason}' \
    > "${ARTIFACT_DIR}/console-flake-result.json"
  write_spyglass_link || true
  echo "Console QE Agent: $1" >&2
  echo "No verified fix proposal produced."
}

if [[ "${JOB_NAME:-}" =~ ^rehearse-([0-9]+)-pull-ci-openshift-console-main-e2e-gcp-console$ ]]; then
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
elif [[ "${_mode}" == rehearsal ]]; then
    echo "Console QE Agent rehearsal mode is inactive outside the Console main rehearsal."
    exit 0
else
  _revision="${CONSOLE_FLAKE_SKILL_REVISION:-}"
fi
if [[ ! "${_revision}" =~ ^([0-9a-f]{40}|main)$ ]]; then
  bootstrap_failure "CONSOLE_FLAKE_SKILL_REVISION must be a release commit or main"
  exit 0
fi

_driver_url="https://raw.githubusercontent.com/openshift/release/${_revision}/ci-operator/config/openshift/console/tools/openshift-console-qe-agent-driver.py"
if ! python3 - "${_driver_url}" "${CONSOLE_AGENT_RUNROOT}/driver.py" "${CONSOLE_FLAKE_DRIVER_SHA256:-}" <<'PY'
import hashlib
import pathlib
import re
import sys
import urllib.request

expected = sys.argv[3]
if not re.fullmatch(r'[0-9a-f]{64}', expected):
    raise ValueError('pinned Console driver SHA-256 is missing or malformed')
with urllib.request.urlopen(sys.argv[1], timeout=30) as response:
    source = response.read(102401)
if len(source) > 102400:
    raise ValueError('pinned Console agent driver exceeds 100 KiB')
if hashlib.sha256(source).hexdigest() != expected:
    raise ValueError('pinned Console agent driver SHA-256 does not match')
compile(source, sys.argv[2], 'exec')
pathlib.Path(sys.argv[2]).write_bytes(source)
PY
then
  bootstrap_failure "reviewed Console agent driver could not be fetched or failed SHA-256 verification"
  exit 0
fi

_driver_source="$(cat "${CONSOLE_AGENT_RUNROOT}/driver.py")"
_driver_digest="$(sha256sum "${CONSOLE_AGENT_RUNROOT}/driver.py")"

if ! python3 "${CONSOLE_AGENT_RUNROOT}/driver.py" init; then
  write_spyglass_link || true
  python3 "${CONSOLE_AGENT_RUNROOT}/driver.py" finalize || true
  exit 0
fi

export CONSOLE_AGENT_INVESTIGATION_DEADLINE=$(( $(date +%s) + 3600 ))
if python3 "${CONSOLE_AGENT_RUNROOT}/driver.py" prepare; then
  python3 "${CONSOLE_AGENT_RUNROOT}/driver.py" baseline || true
  _model_inputs_ready=false
  if python3 "${CONSOLE_AGENT_RUNROOT}/driver.py" model-inputs; then
    _model_inputs_ready=true
  else
    echo "Console QE Agent could not prepare restricted model inputs."
  fi
  _context_digest="$(sha256sum "${CONSOLE_AGENT_RUNROOT}/console-flake-context.json")"
  _selected_digest="$(sha256sum "${CONSOLE_AGENT_RUNROOT}/selected.json")"
  _remaining=$(( CONSOLE_AGENT_INVESTIGATION_DEADLINE - $(date +%s) ))
  if [[ "${_model_inputs_ready}" == true && ${_remaining} -gt 0 ]] && command -v claude >/dev/null 2>&1; then
    export CONSOLE_AGENT_CONTEXT="${ARTIFACT_DIR}/console-flake-evidence/model-context.json"
    export CONSOLE_AGENT_SELECTED="${ARTIFACT_DIR}/console-flake-evidence/model-selected.json"
    export CONSOLE_AGENT_HISTORY="${ARTIFACT_DIR}/console-flake-evidence/history.json"
    export CONSOLE_AGENT_BASELINE="${ARTIFACT_DIR}/console-flake-evidence/baseline.json"
    export CONSOLE_AGENT_DIAGNOSTICS="${ARTIFACT_DIR}/console-flake-evidence/cluster-diagnostics.json"
    export CONSOLE_AGENT_EVIDENCE_DIR="${ARTIFACT_DIR}/console-flake-evidence"
    export CONSOLE_AGENT_ARTIFACT_DIR="${ARTIFACT_DIR}"
    export CONSOLE_AGENT_WORKDIR="${CONSOLE_AGENT_RUNROOT}/agent"
    export GIT_CONFIG_COUNT=1 GIT_CONFIG_KEY_0=safe.directory GIT_CONFIG_VALUE_0='*'
    (
      cd "${CONSOLE_AGENT_WORKDIR}" || exit 1
      timeout "${_remaining}s" env -u SHARED_DIR -u KUBECONFIG \
        -u BRIDGE_KUBEADMIN_PASSWORD -u BRIDGE_HTPASSWD_PASSWORD \
        claude --print --bare --restricted --disable-slash-commands \
        --setting-sources "" --settings "${CONSOLE_AGENT_RUNROOT}/model-settings.json" \
        --add-dir "${ARTIFACT_DIR}" --strict-mcp-config --no-chrome \
        --permission-mode dontAsk --tools "Read,Write,Edit,Grep,Glob" \
        --allowedTools "Read,Write,Edit,Grep,Glob" --disallowedTools "Bash,mcp__*" \
        --model "${CLAUDE_MODEL:-claude-opus-4-6}" --max-budget-usd 5 \
        --no-session-persistence --verbose --output-format stream-json \
        --system-prompt "$(cat "${CONSOLE_AGENT_RUNROOT}/skill.md")" \
        "Read ${CONSOLE_AGENT_SELECTED}, ${CONSOLE_AGENT_CONTEXT}, ${CONSOLE_AGENT_HISTORY}, ${CONSOLE_AGENT_BASELINE}, and ${CONSOLE_AGENT_DIAGNOSTICS}. Investigate only the tests in ${CONSOLE_AGENT_SELECTED}; use the full context only to compare failure patterns. Write preliminary diagnoses and analysis. Follow the standalone Console CI skill." \
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
write_spyglass_link || true
python3 "${CONSOLE_AGENT_RUNROOT}/driver.py" finalize || true
exit 0
