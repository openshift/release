#!/bin/bash
# interop-opp-prow-analyzer step wrapper (INTEROP-9648).
# Canonical source: this repo, tools/prow_analyzer_step/; delivered to
# openshift/release as ci-operator/step-registry/interop/opp/prow-analyzer/
# interop-opp-prow-analyzer-commands.sh. Design authority:
# docs/design/prow-analyzer-step.md.
#
# Lane-neutral best-effort post step: exits 0 on every graceful path.
# Emits a marker-first versioned result line; emits NO JUnit (deliberate
# deviation, design doc section 8). Shell tracing is OFF for the whole
# script; no env dumps; credentials by file-mounted secret -> environment
# only, never argv; CLI streams redirect off the public artifact path.

set -uo pipefail

# ---------------------------------------------------------------- constants
READONLY_PREFIX="OPP-PROW-ANALYZER"
: "${JOB_NAME:=unset-job}"
: "${BUILD_ID:=unset-build}"
: "${ARTIFACT_BASE_DIR:?ARTIFACT_BASE_DIR is required}"
: "${SHARED_DIR:=/tmp}"
ANALYZER_MCP_URL="${ANALYZER_MCP_URL:-https://ship-help-mcp-continuous-release-toolting--ship-help-bot.apps.gpc.ocp-hub.prod.psi.redhat.com/personas/ocp_ai_helpdesk/mcp}"
ANALYZER_SECRET_TOKEN_FILE="${ANALYZER_SECRET_TOKEN_FILE:-/tmp/secrets/ship-help/token}"
ANALYZER_WEBHOOK_FILE="${ANALYZER_WEBHOOK_FILE:-/tmp/secrets/opp-discussion-webhook/url}"
ANALYZER_ATTEMPT_TIMEOUT="${ANALYZER_ATTEMPT_TIMEOUT:-600}"
ANALYZER_TOTAL_TIMEOUT="${ANALYZER_TOTAL_TIMEOUT:-2400}"
ANALYZER_MAX_ATTEMPTS="${ANALYZER_MAX_ATTEMPTS:-3}"
ANALYZER_BACKOFF_SECONDS="${ANALYZER_BACKOFF_SECONDS:-10}"
ANALYZER_CAPACITY="${ANALYZER_CAPACITY:-1}"
ANALYZER_PAYLOAD_LIMIT="${ANALYZER_PAYLOAD_LIMIT:-40000}"
ANALYZER_STATE_FILE="${ANALYZER_STATE_FILE:-${SHARED_DIR}/prow-analyzer-delivery.key}"
ANALYZER_CLI_PATH="${ANALYZER_CLI_PATH:-}"            # empty = compile from source
ANALYZER_SOURCE_PATH="${ANALYZER_SOURCE_PATH:-}"      # local source archive (compile branch)
ANALYZER_SOURCE_URL="${ANALYZER_SOURCE_URL:-https://api.github.com/repos/oramraz/prow-analyzer/tarball/cfe2cb6edcbb6f2d7bc366130cc03318d83a3ccd}"
ANALYZER_SOURCE_SHA256="${ANALYZER_SOURCE_SHA256:-1d46e51412efa76c473910f8975002295ee46cdd62feab3c91254f68f43efa34}"
ANALYZER_VERIFY_ONLY="${ANALYZER_VERIFY_ONLY:-0}"
ANALYZER_JOB_URL="${ANALYZER_JOB_URL:-https://prow.ci.openshift.org/view/gs/test-platform-results-public/logs/${JOB_NAME}/${BUILD_ID}}"

_START_EPOCH="$(date -u +%s)"
_TERMINAL_EMITTED=0
_OUTCOME="error"
_GATE="internal"
_ATTEMPTS=0
_RESPONSE_SHA="none"
_RESPONSE_LEN="none"
_PAYLOAD_CHARS="none"
_IDEMPOTENCY_KEY="none"
_CLEANUP_FILES=""

# ---------------------------------------------------------------- helpers
credential_present() {
    [ -s "${ANALYZER_SECRET_TOKEN_FILE}" ]
}

emit_skeleton() {
    local cred="false"
    if credential_present; then cred="true"; fi
    printf '%s v=1 stage=skeleton job=%s build_id=%s credential_present=%s\n' \
        "${READONLY_PREFIX}" "${JOB_NAME}" "${BUILD_ID}" "${cred}"
}

emit_terminal() {
    [ "${_TERMINAL_EMITTED}" -eq 1 ] && return 0
    _TERMINAL_EMITTED=1
    local cred="false"
    if credential_present; then cred="true"; fi
    local duration=$(( $(date -u +%s) - _START_EPOCH ))
    printf '%s v=1 stage=terminal outcome=%s attempts=%s duration=%ss gate=%s job=%s build_id=%s executing_build=%s analyzed_build=%s artifact_snapshot_time=%s credential_present=%s response_sha256=%s response_length=%s payload_chars=%s idempotency_key=%s\n' \
        "${READONLY_PREFIX}" "${_OUTCOME}" "${_ATTEMPTS}" "${duration}" "${_GATE}" "${JOB_NAME}" \
        "${BUILD_ID}" "${BUILD_ID}" "${BUILD_ID}" "${ARTIFACT_SNAPSHOT_EPOCH:-${_START_EPOCH}}" \
        "${cred}" "${_RESPONSE_SHA}" "${_RESPONSE_LEN}" "${_PAYLOAD_CHARS}" "${_IDEMPOTENCY_KEY}"
}

on_exit() {
    emit_terminal
    if [ -n "${_CLEANUP_FILES}" ]; then
        # shellcheck disable=SC2086
        rm -f ${_CLEANUP_FILES} 2>/dev/null || true
    fi
    exit 0
}

on_term() {
    if [ "${_TERMINAL_EMITTED}" -eq 0 ]; then
        _OUTCOME="timeout"
    fi
    emit_terminal
    exit 0
}

trap on_exit EXIT
trap on_term TERM INT

# sum_junit_failures FILE -> prints "<failures+errors>" or "unparseable"
sum_junit_failures() {
    local file="$1"
    if ! grep -q '<testsuite' "${file}" 2>/dev/null; then
        printf 'unparseable'
        return 0
    fi
    local total=0 match value
    while IFS= read -r match; do
        value="${match#*\"}"
        value="${value%\"}"
        case "${value}" in
            ''|*[!0-9]*) printf 'unparseable'; return 0 ;;
        esac
        total=$(( total + value ))
    done <<EOF
$(grep -oE '(failures|errors)="[0-9]*"' "${file}" 2>/dev/null)
EOF
    printf '%s' "${total}"
}

# ---------------------------------------------------------------- admission gate
# Three-way (design doc section 3): analyze on failure signal / no evidence /
# unparseable evidence; skip only on the green conjunction.
gate_evaluate() {
    local step_dir junit tally any_junit=0 any_unparseable=0
    local total_failures=0 all_markers_passed=1 saw_marker=0
    for step_dir in "${ARTIFACT_BASE_DIR}"/*/; do
        [ -d "${step_dir}" ] || continue
        if [ -f "${step_dir}finished.json" ]; then
            saw_marker=1
            if grep -q '"passed":[[:space:]]*false' "${step_dir}finished.json" 2>/dev/null; then
                all_markers_passed=0
            fi
        fi
        while IFS= read -r junit; do
            [ -f "${junit}" ] || continue
            any_junit=1
            tally="$(sum_junit_failures "${junit}")"
            if [ "${tally}" = "unparseable" ]; then
                any_unparseable=1
            else
                total_failures=$(( total_failures + tally ))
            fi
        done <<EOF
$(find "${step_dir}" -maxdepth 3 -type f \( -name 'junit_*.xml' -o -name 'TEST-*.xml' -o -path '*/junit/*.xml' \) 2>/dev/null)
EOF
    done
    if [ "${total_failures}" -gt 0 ]; then
        printf 'analyze:failure_signal'
        return 0
    fi
    if [ "${all_markers_passed}" -eq 0 ]; then
        printf 'analyze:failure_signal'
        return 0
    fi
    if [ "${any_unparseable}" -eq 1 ]; then
        printf 'analyze:no_evidence'
        return 0
    fi
    if [ "${any_junit}" -eq 0 ] && [ "${saw_marker}" -eq 0 ]; then
        printf 'analyze:no_evidence'
        return 0
    fi
    if [ "${any_junit}" -eq 1 ] && [ "${all_markers_passed}" -eq 1 ] && [ "${saw_marker}" -ge 1 ]; then
        printf 'skip:green_proof'
        return 0
    fi
    printf 'analyze:no_evidence'
}

# ---------------------------------------------------------------- source verify
verify_source() {
    local path="${ANALYZER_SOURCE_PATH}"
    if [ -z "${path}" ]; then
        path="$(mktemp /tmp/prow-analyzer-src.XXXXXX.tar.gz)"
        if ! curl -fsSL --max-time 120 "${ANALYZER_SOURCE_URL}" -o "${path}"; then
            return 1
        fi
    fi
    [ -f "${path}" ] || return 1
    echo "${ANALYZER_SOURCE_SHA256}  ${path}" | sha256sum -c - >/dev/null 2>&1
}

# ---------------------------------------------------------------- analysis block
# The pinned CLI prints: header lines, "URL: <url>", a blank line, the
# analysis prose, then a line "---" and a duration line. Extract the prose.
extract_analysis_block() {
    awk '/^URL: .*/ {seen=1; next} seen {if ($0 == "---") exit; if (!started && $0 == "") next; started=1; print}' "$1"
}

# ---------------------------------------------------------------- main
emit_skeleton

ARTIFACT_SNAPSHOT_EPOCH="$(date -u +%s)"

if [ "${ANALYZER_VERIFY_ONLY}" = "1" ]; then
    if verify_source; then
        _OUTCOME="skipped"; _GATE="verify_only"
    else
        _OUTCOME="error"; _GATE="source_sha_mismatch"
    fi
    exit 0
fi

_GATE="$(gate_evaluate)"

if [ "${_GATE}" = "skip:green_proof" ]; then
    _OUTCOME="skipped"
    exit 0
fi

# wrapper-side decline: a delivery for this build already happened in this run
if [ -s "${ANALYZER_STATE_FILE}" ] && grep -q "^${BUILD_ID}:" "${ANALYZER_STATE_FILE}" 2>/dev/null; then
    _OUTCOME="no_analysis"; _GATE="duplicate_delivery_suppressed"
    exit 0
fi

if ! credential_present; then
    _OUTCOME="error"; _GATE="credential_absent"
    exit 0
fi

if [ "${ANALYZER_CAPACITY}" -lt 1 ]; then
    _OUTCOME="deferred_capacity"; _GATE="capacity_exhausted"
    exit 0
fi

if [ -z "${ANALYZER_CLI_PATH}" ]; then
    # compile branch: fail closed on source mismatch; token stays unread until
    # the build completes (design doc section 2) -- the read above only checks
    # presence, the value is materialized here at the earliest.
    if ! verify_source; then
        _OUTCOME="error"; _GATE="source_sha_mismatch"
        exit 0
    fi
    ANALYZER_CLI_PATH="$(mktemp -d /tmp/prow-analyzer-build.XXXXXX)"
    if ! tar -xzf "${ANALYZER_SOURCE_PATH:-/dev/null}" -C "${ANALYZER_CLI_PATH}" 2>/dev/null; then
        _OUTCOME="error"; _GATE="source_extract_failed"
        exit 0
    fi
    if ! (cd "${ANALYZER_CLI_PATH}"/*/ && go build -o prow-analyzer ./cmd/prow-analyzer 2>/dev/null); then
        _OUTCOME="error"; _GATE="compile_failed"
        exit 0
    fi
    ANALYZER_CLI_PATH="$(find "${ANALYZER_CLI_PATH}" -name prow-analyzer -type f | head -1)"
fi

TOKEN="$(cat "${ANALYZER_SECRET_TOKEN_FILE}")"
CLI_OUT="$(mktemp /tmp/prow-analyzer-cli-out.XXXXXX)"
CLI_ERR="$(mktemp /tmp/prow-analyzer-cli-err.XXXXXX)"
ANALYSIS_BLOCK="$(mktemp /tmp/prow-analyzer-block.XXXXXX)"
_CLEANUP_FILES="${CLI_OUT} ${CLI_ERR} ${ANALYSIS_BLOCK}"

attempt_loop() {
    local attempt rc elapsed classification
    for attempt in $(seq 1 "${ANALYZER_MAX_ATTEMPTS}"); do
        _ATTEMPTS="${attempt}"
        elapsed=$(( $(date -u +%s) - _START_EPOCH ))
        if [ "${elapsed}" -ge "${ANALYZER_TOTAL_TIMEOUT}" ]; then
            _OUTCOME="timeout"
            return 0
        fi
        rc=0
        SHIP_HELP_MCP_URL="${ANALYZER_MCP_URL}" \
        SHIP_HELP_MCP_TOKEN="${TOKEN}" \
        timeout --signal=TERM --kill-after=5 "${ANALYZER_ATTEMPT_TIMEOUT}" \
            "${ANALYZER_CLI_PATH}" analyze "${ANALYZER_JOB_URL}" \
            >"${CLI_OUT}" 2>"${CLI_ERR}" || rc=$?
        if [ "${rc}" -eq 0 ]; then
            extract_analysis_block "${CLI_OUT}" > "${ANALYSIS_BLOCK}"
            if [ -s "${ANALYSIS_BLOCK}" ]; then
                _OUTCOME="success"
                return 0
            fi
            _OUTCOME="error"; _GATE="empty_analysis_block"
            return 0
        fi
        if [ "${rc}" -eq 124 ] || [ "${rc}" -eq 137 ]; then
            classification="timeout"
        elif grep -qiE '429|rate.?limit|too many requests' "${CLI_ERR}" "${CLI_OUT}" 2>/dev/null; then
            classification="rate_limited"
        elif grep -qiE 'HTTP 40[13]|HTTP 500|unauthorized|forbidden' "${CLI_ERR}" 2>/dev/null; then
            classification="auth_or_server"
        else
            classification="error"
        fi
        if [ "${classification}" = "timeout" ]; then
            _OUTCOME="timeout"
            return 0
        fi
        if [ "${classification}" = "rate_limited" ]; then
            _OUTCOME="rate_limited"
            return 0
        fi
        sleep "${ANALYZER_BACKOFF_SECONDS}"
    done
    _OUTCOME="error"
}
attempt_loop

if [ "${_OUTCOME}" != "success" ]; then
    exit 0
fi

# ------------------------------------------------------- success: extract + deliver once
RESPONSE_SHA="$(sha256sum "${ANALYSIS_BLOCK}" | cut -d' ' -f1)"
_RESPONSE_SHA="${RESPONSE_SHA}"
_RESPONSE_LEN="$(wc -c < "${ANALYSIS_BLOCK}" | tr -d ' ')"
_IDEMPOTENCY_KEY="${BUILD_ID}:${RESPONSE_SHA}"

PAYLOAD_FILE="$(mktemp /tmp/prow-analyzer-payload.XXXXXX)"
_CLEANUP_FILES="${_CLEANUP_FILES} ${PAYLOAD_FILE}"
{
    printf '*Prow Analyzer* — %s — build %s\n`%s`\n\n' "${JOB_NAME}" "${BUILD_ID}" "${_IDEMPOTENCY_KEY}"
    cat "${ANALYSIS_BLOCK}"
} > "${PAYLOAD_FILE}"
PAYLOAD_CHARS="$(wc -c < "${PAYLOAD_FILE}" | tr -d ' ')"
if [ "${PAYLOAD_CHARS}" -gt "${ANALYZER_PAYLOAD_LIMIT}" ]; then
    head -c "${ANALYZER_PAYLOAD_LIMIT}" "${PAYLOAD_FILE}" > "${PAYLOAD_FILE}.trunc"
    printf '\n[truncated=true]' >> "${PAYLOAD_FILE}.trunc"
    mv "${PAYLOAD_FILE}.trunc" "${PAYLOAD_FILE}"
    PAYLOAD_CHARS="$(wc -c < "${PAYLOAD_FILE}" | tr -d ' ')"
fi
_PAYLOAD_CHARS="${PAYLOAD_CHARS}"

WEBHOOK_URL="$(cat "${ANALYZER_WEBHOOK_FILE}" 2>/dev/null)"
SINK_STATUS_FILE="$(mktemp /tmp/prow-analyzer-sink.XXXXXX)"
_CLEANUP_FILES="${_CLEANUP_FILES} ${SINK_STATUS_FILE}"
SINK_RC=0
if [ -z "${WEBHOOK_URL}" ]; then
    SINK_RC=99
else
    python3 - "$PAYLOAD_FILE" "$WEBHOOK_URL" "$SINK_STATUS_FILE" <<'PYEOF' || SINK_RC=$?
import json, sys, urllib.request
payload_file, url, status_file = sys.argv[1], sys.argv[2], sys.argv[3]
text = open(payload_file).read()
body = json.dumps({"text": text}).encode()
req = urllib.request.Request(url, data=body, headers={"Content-Type": "application/json"})
try:
    with urllib.request.urlopen(req, timeout=60) as resp:
        open(status_file, "w").write(str(resp.status))
except urllib.error.HTTPError as e:
    open(status_file, "w").write(str(e.code))
    sys.exit(1)
except Exception:
    open(status_file, "w").write("0")
    sys.exit(2)
PYEOF
fi

if [ "${SINK_RC}" -eq 0 ]; then
    printf '%s:%s\n' "${BUILD_ID}" "${RESPONSE_SHA}" >> "${ANALYZER_STATE_FILE}"
elif [ "${SINK_RC}" -eq 99 ]; then
    _OUTCOME="sink_error"; _GATE="webhook_url_absent"
else
    SINK_STATUS="$(cat "${SINK_STATUS_FILE}" 2>/dev/null || echo 0)"
    case "${SINK_STATUS}" in
        2*|0) _OUTCOME="sink_error" ;;
        4*) if [ "${SINK_STATUS}" = "429" ]; then _OUTCOME="sink_error"; else _OUTCOME="sink_rejected"; fi ;;
        *) _OUTCOME="sink_error" ;;
    esac
fi

exit 0
