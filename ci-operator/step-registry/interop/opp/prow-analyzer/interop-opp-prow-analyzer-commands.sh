#!/bin/bash
# interop-opp-prow-analyzer step wrapper (INTEROP-9648).
# Canonical source: the opp-interop-testing workspace,
# sub-projects/tools-session/src/tools_session/prow_analyzer_step/;
# delivered to openshift/release as ci-operator/step-registry/interop/opp/
# prow-analyzer/interop-opp-prow-analyzer-commands.sh. Design authority:
# docs/design/prow-analyzer-step.md.
#
# Lane-neutral best-effort post step: exits 0 on every graceful path.
# Emits a marker-first versioned result line; emits NO JUnit (deliberate
# deviation, design doc section 8). Shell tracing is ON (strict-mode
# requirement) but scoped OFF around every credential-bearing read,
# test, and invocation: the token and webhook URL never appear in the
# trace, and analysis prose never transits a shell variable. No env
# dumps; credentials by file-mounted secret -> environment only, never
# argv; CLI streams redirect off the public artifact path.
# Errexit is ON (set -e): every failure path routes through the EXIT trap,
# which emits the terminal line and forces exit 0 - an unhandled command
# failure degrades to outcome=error, never a red job.
#
# Outcome vocabulary (design doc section 5): wrapper-level faults are
# outcome=error. A failure of the analysis machinery on an admitted
# analyze path (CLI non-zero after the retry budget, empty analysis
# block) is outcome=analysis_failed: the analyzed build's own state
# stays in gate=analyze:*, and the step marker stays green BY DESIGN
# (exit 0; a failed post step would fail the lane), so the distinct
# outcome is what makes that masked-green shape legible from public
# artifacts (rehearsal 2119808664779886592, INTEROP-9648).

set -euxo pipefail
shopt -s inherit_errexit

# ---------------------------------------------------------------- constants
READONLY_PREFIX="OPP-PROW-ANALYZER"
# Prow injects JOB_NAME/BUILD_ID into every step container; they are
# required after the traps are registered (see below) - a missing identity
# degrades loudly to outcome=error instead of fabricating a well-formed
# result line (job=unset-job reads as a real job in downstream evidence).
# Evidence source (empirical, rehearsal 2117256157000110080, PR 88057):
# each step pod owns an ISOLATED emptyDir, so the <test>/<step>/ tree the
# admission gate needs does not exist in this container at all - the
# two-levels-up derivation from $ARTIFACT_DIR resolved to / in production
# and the gate read analyze:no_evidence on a red run (the earlier
# one-level-up form had the same flaw, CodeRabbit r4426804531; both
# derivations modeled the GCS layout as the container layout). The
# production medium is the build's public GCS bucket: the per-step
# artifact syncer uploads <test>/<step>/ trees - including each step's
# finished.json marker - as steps complete, so by the time this post step
# runs, the earlier steps are visible there. ARTIFACT_BASE_DIR remains an
# EXPLICIT local override (dry-run matrix, local fixtures); it is never
# derived from ARTIFACT_DIR.
GCS_BUCKET="${GCS_BUCKET:-test-platform-results-public}"
GCS_API_ROOT="${GCS_API_ROOT:-https://storage.googleapis.com/storage/v1/b/${GCS_BUCKET}/o}"
GCS_MEDIA_ROOT="${GCS_MEDIA_ROOT:-https://storage.googleapis.com/${GCS_BUCKET}}"
GCS_LIST_TIMEOUT="${GCS_LIST_TIMEOUT:-60}"
GCS_FETCH_TIMEOUT="${GCS_FETCH_TIMEOUT:-60}"
GCS_POLL_ATTEMPTS="${GCS_POLL_ATTEMPTS:-3}"
GCS_POLL_INTERVAL="${GCS_POLL_INTERVAL:-15}"
: "${SHARED_DIR:=/tmp}"
# Step-config-declared variables (CIOP-4 double-underscore names). Their
# values live ONLY in the step ref YAML (CIOP-5.3: no script-side defaults
# - a second default here is a dual source of truth, and the two copies
# have already drifted once):
#   INTEROP__OPP__PROW_ANALYZER__SHIP_HELP_MCP_URL
#   INTEROP__OPP__PROW_ANALYZER__SOURCE_URL
#   INTEROP__OPP__PROW_ANALYZER__SOURCE_SHA256
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
ANALYZER_VERIFY_ONLY="${ANALYZER_VERIFY_ONLY:-0}"
# Empty means "derive from the build identity" (analyzer_job_url below):
# the derivation needs the helpers, and a rehearsal or presubmit build does
# not live under logs/ at all - rehearsals are published at
# pr-logs/pull/<org_repo>/<N>/<JOB_NAME>/<BUILD_ID> (the same identity path
# the admission gate already uses), so a logs/-only default pointed the
# analyzer at a nonexistent build. An explicit ANALYZER_JOB_URL still wins.
ANALYZER_JOB_URL="${ANALYZER_JOB_URL:-}"

_START_EPOCH="$(date -u +%s)"
_TERMINAL_EMITTED=0
_OUTCOME="error"
_GATE="internal"
_ATTEMPTS=0
_RESPONSE_SHA="none"
_RESPONSE_LEN="none"
_PAYLOAD_CHARS="none"
_IDEMPOTENCY_KEY="none"
_SINK_STATUS="none"
typeset -a _CLEANUP_FILES=()

# ---------------------------------------------------------------- helpers
credential_present() {
    [ -s "${ANALYZER_SECRET_TOKEN_FILE}" ]
}

emit_skeleton() {
    typeset cred="false"
    if credential_present; then cred="true"; fi
    printf '%s v=1 stage=skeleton job=%s build_id=%s credential_present=%s\n' \
        "${READONLY_PREFIX}" "${JOB_NAME}" "${BUILD_ID}" "${cred}"
}

emit_terminal() {
    [ "${_TERMINAL_EMITTED}" -eq 1 ] && return 0
    _TERMINAL_EMITTED=1
    typeset cred="false"
    if credential_present; then cred="true"; fi
    typeset duration=$(( $(date -u +%s) - _START_EPOCH ))
    # JOB_NAME/BUILD_ID tolerate absence here only: the required-identity
    # check below can fail before any value exists, and the EXIT trap must
    # still emit a terminal line (outcome=error) and force exit 0.
    printf '%s v=1 stage=terminal outcome=%s attempts=%s duration=%ss gate=%s job=%s build_id=%s executing_build=%s analyzed_build=%s artifact_snapshot_time=%s credential_present=%s response_sha256=%s response_length=%s payload_chars=%s idempotency_key=%s sink_status=%s\n' \
        "${READONLY_PREFIX}" "${_OUTCOME}" "${_ATTEMPTS}" "${duration}" "${_GATE}" "${JOB_NAME:-unknown-job}" \
        "${BUILD_ID:-unknown-build}" "${BUILD_ID:-unknown-build}" "${BUILD_ID:-unknown-build}" "${ARTIFACT_SNAPSHOT_EPOCH:-${_START_EPOCH}}" \
        "${cred}" "${_RESPONSE_SHA}" "${_RESPONSE_LEN}" "${_PAYLOAD_CHARS}" "${_IDEMPOTENCY_KEY}" "${_SINK_STATUS}"
}

on_exit() {
    emit_terminal
    if [ "${#_CLEANUP_FILES[@]}" -gt 0 ]; then
        rm -f -- "${_CLEANUP_FILES[@]}" || true
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

# Required Prow identity (see constants): the expansion error routes
# through the EXIT trap - terminal line outcome=error, exit 0.
: "${JOB_NAME:?}"
: "${BUILD_ID:?}"

# sum_junit_failures FILE -> prints "<failures+errors>" or "unparseable"
sum_junit_failures() {
    typeset file="$1"
    if ! grep -q '<testsuite' "${file}"; then
        printf 'unparseable'
        return 0
    fi
    typeset total=0 match value
    # grep exits 1 on zero attribute matches; the empty result is handled
    # below, so keep errexit out of the substitution.
    typeset matches
    matches="$(grep -oE '(failures|errors)="[0-9]*"' "${file}" || true)"
    # A testsuite element without failures=/errors= attributes is malformed
    # JUnit, not a green tally: counting it as 0 would fabricate green
    # proof, and the gate's asymmetry rule requires positive green proof.
    if [ -z "${matches}" ]; then
        printf 'unparseable'
        return 0
    fi
    while IFS= read -r match; do
        value="${match#*\"}"
        value="${value%\"}"
        case "${value}" in
            ''|*[!0-9]*) printf 'unparseable'; return 0 ;;
        esac
        total=$(( total + value ))
    done <<EOF
${matches}
EOF
    printf '%s' "${total}"
}

# ---------------------------------------------------------------- admission gate
# Three-way vocabulary (design doc section 3) plus one honest degradation
# label: analyze on failure signal / no evidence / unparseable evidence;
# skip only on the green conjunction; analyze:runtime_tree_unavailable
# when no step-like evidence could be READ AT ALL (never a false
# no_evidence - an unreadable tree is not evidence of absence).
#
# build_prow_path: the build's own Prow/GCS path, from its identity only
# (JOB_NAME/BUILD_ID plus the Prow-injected PULL_NUMBER and
# REPO_OWNER/REPO_NAME, which ci-operator passes into every step container).
# pr-logs/pull/ carries both rehearsal and presubmit builds; only periodics
# live under logs/. A rehearsal is recognised by its Prow-assigned name
# (rehearse-<N>-<job>) - which is also the design-doc contract - and any
# other build by PULL_NUMBER.
build_prow_path() {
    typeset org_repo="openshift_release"
    if [ -n "${REPO_OWNER:-}" ] && [ -n "${REPO_NAME:-}" ]; then
        org_repo="${REPO_OWNER}_${REPO_NAME}"
    fi
    typeset pr=""
    case "${JOB_NAME}" in
        rehearse-[0-9]*-*)
            pr="${JOB_NAME#rehearse-}"; pr="${pr%%-*}"
            ;;
        *)
            pr="${PULL_NUMBER:-}"
            ;;
    esac
    if [ -n "${pr}" ]; then
        printf 'pr-logs/pull/%s/%s/%s/%s' "${org_repo}" "${pr}" "${JOB_NAME}" "${BUILD_ID}"
    else
        printf 'logs/%s/%s' "${JOB_NAME}" "${BUILD_ID}"
    fi
}

gcs_prefix_for_job() {
    # Local override first (explicit ARTIFACT_GCS_PREFIX), else the build's
    # public GCS tree over HTTPS.
    if [ -n "${ARTIFACT_GCS_PREFIX:-}" ]; then
        printf '%s' "${ARTIFACT_GCS_PREFIX}"
        return 0
    fi
    build_prow_path
}

# analyzer_job_url: the Prow view URL of the build the CLI should analyze.
# Same identity path as the gate, but deliberately NOT ARTIFACT_GCS_PREFIX:
# that override retargets the evidence source only, while an explicitly
# supplied ANALYZER_JOB_URL is the way to analyze a different build.
analyzer_job_url() {
    printf 'https://prow.ci.openshift.org/view/gs/%s/%s' \
        "${GCS_BUCKET}" "$(build_prow_path)"
}

# gcs_list_build_objects <prefix> <outfile>: object names, one per line,
# paginated; returns non-zero when the listing itself fails.
gcs_list_build_objects() {
    typeset prefix="$1" out="$2" token=""
    # the pagination scratch files are temp files too: register them so
    # on_exit removes them (every other scratch file follows this pattern)
    _CLEANUP_FILES+=("${out}.page" "${out}.token")
    : > "${out}"
    while :; do
        if [ -n "${token}" ]; then
            set -- --data-urlencode "pageToken=${token}"
        else
            set --
        fi
        curl -fsSL -G --max-time "${GCS_LIST_TIMEOUT}" "${GCS_API_ROOT}" \
            --data-urlencode "prefix=${prefix}" \
            --data-urlencode "maxResults=1000" \
            "$@" -o "${out}.page" || return 1
        if ! python3 - "${out}.page" "${out}" > "${out}.token" <<'PYEOF'
import json, sys
page, out = sys.argv[1], sys.argv[2]
try:
    d = json.load(open(page))
except Exception:
    sys.exit(3)
with open(out, "a") as f:
    for item in d.get("items", []):
        f.write(item["name"] + "\n")
print(d.get("nextPageToken", ""))
PYEOF
        then
            return 1
        fi
        token="$(cat "${out}.token")"
        [ -z "${token}" ] && break
    done
    return 0
}

gcs_fetch_object() { # <object-name> <outfile>
    curl -fsSL --max-time "${GCS_FETCH_TIMEOUT}" "${GCS_MEDIA_ROOT}/$1" -o "$2"
}

_MARKER_RE='(^|/)finished\.json$'
_JUNIT_RE='(^|/)(junit_[^/]*|TEST-[^/]*)\.xml$|/junit/[^/]*\.xml$'

gate_evaluate() {
    typeset step_dir junit tally any_junit=0 any_unparseable=0
    typeset total_failures=0 all_markers_passed=1 saw_marker=0
    typeset listing obj fetched attempt saw_step_like=0
    if [ -n "${ARTIFACT_BASE_DIR:-}" ]; then
        # explicit local override: the original scan semantics. A base that
        # cannot be scanned at all is runtime_tree_unavailable; a scanned
        # base with no step-like children is genuinely no_evidence.
        if [ ! -d "${ARTIFACT_BASE_DIR}" ]; then
            printf 'analyze:runtime_tree_unavailable'
            return 0
        fi
        for step_dir in "${ARTIFACT_BASE_DIR}"/*/; do
            [ -d "${step_dir}" ] || continue
            if [ -f "${step_dir}finished.json" ]; then
                saw_marker=1; saw_step_like=1
                if grep -q '"passed":[[:space:]]*false' "${step_dir}finished.json"; then
                    all_markers_passed=0
                fi
            fi
            while IFS= read -r junit; do
                [ -f "${junit}" ] || continue
                any_junit=1; saw_step_like=1
                tally="$(sum_junit_failures "${junit}")"
                if [ "${tally}" = "unparseable" ]; then
                    any_unparseable=1
                else
                    total_failures=$(( total_failures + tally ))
                fi
            done <<EOF
$(find "${step_dir}" -maxdepth 3 -type f \( -name 'junit_*.xml' -o -name 'TEST-*.xml' -o -path '*/junit/*.xml' \))
EOF
        done
    else
        # production: the build's public GCS tree over HTTPS. Bounded poll:
        # the per-step syncer uploads progressively, and earlier steps
        # should already be visible when this post step starts.
        listing="$(mktemp /tmp/prow-analyzer-listing.XXXXXX)"
        _CLEANUP_FILES+=("${listing}")
        typeset prefix; prefix="$(gcs_prefix_for_job)"
        for attempt in $(seq 1 "${GCS_POLL_ATTEMPTS}"); do
            if gcs_list_build_objects "${prefix}/artifacts" "${listing}" \
               && grep -qE "${_MARKER_RE}|${_JUNIT_RE}" "${listing}"; then
                saw_step_like=1
                break
            fi
            [ "${attempt}" -lt "${GCS_POLL_ATTEMPTS}" ] && sleep "${GCS_POLL_INTERVAL}"
        done
        if [ "${saw_step_like}" -eq 0 ]; then
            printf 'analyze:runtime_tree_unavailable'
            return 0
        fi
        while IFS= read -r obj; do
            [ -z "${obj}" ] && continue
            saw_marker=1
            fetched="$(mktemp /tmp/prow-analyzer-marker.XXXXXX)"
            _CLEANUP_FILES+=("${fetched}")
            if ! gcs_fetch_object "${obj}" "${fetched}"; then
                # an unreadable marker is neither a pass nor a failure
                # signal: it denies green proof and reads as unparseable
                any_unparseable=1
            elif grep -q '"passed":[[:space:]]*false' "${fetched}"; then
                all_markers_passed=0
            fi
        done <<EOF
$(grep -E "${_MARKER_RE}" "${listing}")
EOF
        while IFS= read -r obj; do
            [ -z "${obj}" ] && continue
            any_junit=1
            fetched="$(mktemp /tmp/prow-analyzer-junit.XXXXXX)"
            _CLEANUP_FILES+=("${fetched}")
            if gcs_fetch_object "${obj}" "${fetched}"; then
                tally="$(sum_junit_failures "${fetched}")"
                if [ "${tally}" = "unparseable" ]; then
                    any_unparseable=1
                else
                    total_failures=$(( total_failures + tally ))
                    # The gate reads total_failures first: a single positive
                    # tally already decides analyze:failure_signal, so the
                    # remaining JUnit fetches cannot change the outcome. Stop
                    # here - a full-stack build publishes 26-28 matching
                    # JUnit objects and each fetch is bounded by
                    # GCS_FETCH_TIMEOUT, so a full scan can eat most of the
                    # ANALYZER_TOTAL_TIMEOUT budget before the first CLI call.
                    if [ "${total_failures}" -gt 0 ]; then
                        break
                    fi
                fi
            else
                # an unreadable junit is not green proof either
                any_unparseable=1
            fi
        done <<EOF
$(grep -E "${_JUNIT_RE}" "${listing}")
EOF
    fi
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
# Resolves the source archive path: either the pre-provisioned
# ANALYZER_SOURCE_PATH, or a download from the step-config-declared
# INTEROP__OPP__PROW_ANALYZER__SOURCE_URL. On success the
# sha256 has been verified and the resolved path is exported as
# ANALYZER_SOURCE_RESOLVED (the caller extracts from THAT; the pre-rehearsal
# build 2116229379922071552 failed extracting /dev/null because the downloaded
# path never left this function).
verify_source() {
    typeset path="${ANALYZER_SOURCE_PATH}"
    if [ -z "${path}" ]; then
        path="$(mktemp /tmp/prow-analyzer-src.XXXXXX.tar.gz)"
        _CLEANUP_FILES+=("${path}")
        if ! curl -fsSL --max-time 120 "${INTEROP__OPP__PROW_ANALYZER__SOURCE_URL}" -o "${path}"; then
            return 1
        fi
    fi
    [ -f "${path}" ] || return 1
    if echo "${INTEROP__OPP__PROW_ANALYZER__SOURCE_SHA256}  ${path}" | sha256sum -c - >/dev/null; then
        ANALYZER_SOURCE_RESOLVED="${path}"
        return 0
    fi
    return 1
}

# ---------------------------------------------------------------- analysis block
# The pinned CLI prints: header lines, "URL: <url>", a blank line, the
# analysis prose, then a line "---" and a duration line. Extract the prose.
extract_analysis_block() {
    awk '/^URL: .*/ {seen=1; next} seen {if ($0 == "---") exit; if (!started && $0 == "") next; started=1; print}' "$1"
}

# ---------------------------------------------------------------- main
emit_skeleton

# Resolve the analysis target once the helpers exist: an explicit
# ANALYZER_JOB_URL is taken verbatim, otherwise the current build's own Prow
# path (rehearsals and presubmits under pr-logs/pull/, periodics under logs/).
if [ -z "${ANALYZER_JOB_URL}" ]; then
    ANALYZER_JOB_URL="$(analyzer_job_url)"
fi

ARTIFACT_SNAPSHOT_EPOCH="$(date -u +%s)"
# graceful degradation moved into the gate: an unreadable evidence source
# labels analyze:runtime_tree_unavailable (never a false no_evidence) and
# still proceeds toward analysis - skip stays reserved for green proof.

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
if [ -s "${ANALYZER_STATE_FILE}" ] && grep -q "^${BUILD_ID}:" "${ANALYZER_STATE_FILE}"; then
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
    if ! tar -xzf "${ANALYZER_SOURCE_RESOLVED}" -C "${ANALYZER_CLI_PATH}"; then
        _OUTCOME="error"; _GATE="source_extract_failed"
        exit 0
    fi
    # Harden the Go toolchain env for the step container: HOME/GOCACHE/GOPATH
    # must resolve to writable paths or go build fails before any module work
    # (rehearsal 2116279745099337728: compile_failed with the error swallowed).
    export HOME="${HOME:-/tmp}"
    export GOCACHE="${GOCACHE:-/tmp/prow-analyzer-gocache}"
    export GOPATH="${GOPATH:-/tmp/prow-analyzer-gopath}"
    _GO_BUILD_ERR="$(mktemp /tmp/prow-analyzer-goerr.XXXXXX)"
    _CLEANUP_FILES+=("${_GO_BUILD_ERR}")
    # -mod=mod overrides a builder-image GOFLAGS=-mod=vendor: the pinned
    # archive's vendor/modules.txt is stale, and CI golang images default to
    # vendored builds (rehearsal 2116335159719497728: "inconsistent vendoring").
    if ! (cd "${ANALYZER_CLI_PATH}"/*/ && go build -mod=mod -o prow-analyzer ./cmd/prow-analyzer 2>"${_GO_BUILD_ERR}"); then
        # Self-diagnosing note line (metadata-only: go toolchain errors carry
        # paths/URLs, never analysis prose or credentials). Spaces become ~ so
        # the key=value result-line grammar stays parseable. Skip go module
        # progress lines first (CodeRabbit r4429697363): with an empty module
        # cache Go prints "go: downloading ..." before any failure, and a
        # first-line pick would report the progress message instead of the
        # error. Single awk process (no early-exit reader pipeline): under
        # set -euo pipefail a grep -m1 | head pipeline can die on SIGPIPE and
        # abort this error handler itself.
        _GO_DETAIL="$(awk '!/^go: (downloading|finding|fetching)/ && NF { gsub(/ /, "~"); print substr($0, 1, 200); exit }' "${_GO_BUILD_ERR}")"
        printf 'OPP-PROW-ANALYZER v=1 stage=note what=compile_failed detail=%s\n' "${_GO_DETAIL:-no_stderr}"
        _OUTCOME="error"; _GATE="compile_failed"
        exit 0
    fi
    ANALYZER_CLI_PATH="$(find "${ANALYZER_CLI_PATH}" -name prow-analyzer -type f -print -quit)"
fi

# Red Hat IT root CA: the MCP endpoint's chain terminates at the internal
# RH IT root, absent from stock CI image trust stores (rehearsal
# 2116720842141339648: three CLI attempts failed TLS). When the CA bundle
# is mounted (GSM ship-help-mcp/ca, same credential group as the token),
# scope SSL_CERT_FILE to the CLI attempts only: the source fetch
# (api.github.com) and the sink delivery (Slack webhook) must keep the
# public roots.
ANALYZER_CA_FILE="${ANALYZER_CA_FILE:-${ANALYZER_SECRET_TOKEN_FILE%/*}/ca}"
_SSL_CERT_FILE_WAS_SET=0
if [ -s "${ANALYZER_CA_FILE}" ] && [ -z "${SSL_CERT_FILE:-}" ]; then
    export SSL_CERT_FILE="${ANALYZER_CA_FILE}"
    _SSL_CERT_FILE_WAS_SET=1
fi

# xtrace scoping: prefix assignments are traced with their values, so
# the token-bearing CLI invocation runs with tracing off (BASH-1 requires
# tracing; BASH-7 scopes it away from credentials).
{ set +x; } 2>/dev/null
TOKEN="$(cat "${ANALYZER_SECRET_TOKEN_FILE}")"
{ set -x; } 2>/dev/null
CLI_OUT="$(mktemp /tmp/prow-analyzer-cli-out.XXXXXX)"
CLI_ERR="$(mktemp /tmp/prow-analyzer-cli-err.XXXXXX)"
ANALYSIS_BLOCK="$(mktemp /tmp/prow-analyzer-block.XXXXXX)"
_CLEANUP_FILES+=("${CLI_OUT}" "${CLI_ERR}" "${ANALYSIS_BLOCK}")

attempt_loop() {
    typeset attempt rc elapsed classification
    for attempt in $(seq 1 "${ANALYZER_MAX_ATTEMPTS}"); do
        _ATTEMPTS="${attempt}"
        elapsed=$(( $(date -u +%s) - _START_EPOCH ))
        if [ "${elapsed}" -ge "${ANALYZER_TOTAL_TIMEOUT}" ]; then
            _OUTCOME="timeout"
            return 0
        fi
        rc=0
        { set +x; } 2>/dev/null
        SHIP_HELP_MCP_URL="${INTEROP__OPP__PROW_ANALYZER__SHIP_HELP_MCP_URL}" \
        SHIP_HELP_MCP_TOKEN="${TOKEN}" \
        timeout --signal=TERM --kill-after=5 "${ANALYZER_ATTEMPT_TIMEOUT}" \
            "${ANALYZER_CLI_PATH}" analyze "${ANALYZER_JOB_URL}" \
            >"${CLI_OUT}" 2>"${CLI_ERR}" || rc=$?
        { set -x; } 2>/dev/null
        if [ "${rc}" -eq 0 ]; then
            extract_analysis_block "${CLI_OUT}" > "${ANALYSIS_BLOCK}"
            if [ -s "${ANALYSIS_BLOCK}" ]; then
                _OUTCOME="success"
                return 0
            fi
            _OUTCOME="analysis_failed"; _GATE="empty_analysis_block"
            return 0
        fi
        if [ "${rc}" -eq 124 ] || [ "${rc}" -eq 137 ]; then
            classification="timeout"
        elif grep -qiE '429|rate.?limit|too many requests' "${CLI_ERR}" "${CLI_OUT}"; then
            classification="rate_limited"
        elif grep -qiE 'HTTP 40[13]|HTTP 500|unauthorized|forbidden' "${CLI_ERR}"; then
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
    # Self-diagnosing note line on CLI failure (metadata-only: toolchain and
    # transport errors, never analysis prose or credentials). Rehearsal
    # 2116720842141339648: three failed attempts were unattributable because
    # CLI_ERR was deleted by cleanup before anything recorded it.
    # Fixed-vocabulary diagnostic only (CodeRabbit r4434581019, Major
    # Security): the pinned CLI can carry MCP response bodies in its stderr
    # on HTTP errors, so raw stderr never reaches the public log.
    _CLI_DETAIL="cli_error"
    if [ ! -s "${CLI_ERR}" ]; then
        _CLI_DETAIL="no_stderr"
    elif grep -qiE 'certificate signed by unknown authority|x509:' "${CLI_ERR}"; then
        _CLI_DETAIL="tls_unknown_authority"
    elif grep -qiE 'connection refused|no route to host|i/o timeout' "${CLI_ERR}"; then
        _CLI_DETAIL="network_unreachable"
    fi
    printf 'OPP-PROW-ANALYZER v=1 stage=note what=cli_failed classification=%s detail=%s\n' \
        "${classification}" "${_CLI_DETAIL}"
    # Not outcome=error: the analysis machinery failed on an admitted
    # analyze path (the analyzed build's redness is gate=analyze:*), and
    # the step marker is green by design - the distinct outcome keeps
    # the masked-green shape attributable from the terminal line alone.
    _OUTCOME="analysis_failed"
}
attempt_loop
if [ "${_SSL_CERT_FILE_WAS_SET}" -eq 1 ]; then
    unset SSL_CERT_FILE
fi

if [ "${_OUTCOME}" != "success" ]; then
    exit 0
fi

# ------------------------------------------------------- success: extract + deliver once
RESPONSE_SHA="$(sha256sum "${ANALYSIS_BLOCK}" | cut -d' ' -f1)"
_RESPONSE_SHA="${RESPONSE_SHA}"
_RESPONSE_LEN="$(wc -c < "${ANALYSIS_BLOCK}" | tr -d ' ')"
_IDEMPOTENCY_KEY="${BUILD_ID}:${RESPONSE_SHA}"

PAYLOAD_FILE="$(mktemp /tmp/prow-analyzer-payload.XXXXXX)"
_CLEANUP_FILES+=("${PAYLOAD_FILE}")
{
    printf '*Prow Analyzer* — %s — build %s\n`%s`\n\n' "${JOB_NAME}" "${BUILD_ID}" "${_IDEMPOTENCY_KEY}"
    cat "${ANALYSIS_BLOCK}"
} > "${PAYLOAD_FILE}"
PAYLOAD_CHARS="$(wc -c < "${PAYLOAD_FILE}" | tr -d ' ')"
if [ "${PAYLOAD_CHARS}" -gt "${ANALYZER_PAYLOAD_LIMIT}" ]; then
    # Truncate at a UTF-8 character boundary and reserve space for the
    # truncation marker (CodeRabbit r4426804565): a byte-level `head -c` cut
    # can split a multibyte character, and the sink-side open().read() then
    # raises a decode error, so a long analysis would receive no delivery.
    python3 - "${PAYLOAD_FILE}" "${ANALYZER_PAYLOAD_LIMIT}" <<'PYEOF'
import sys
path, limit = sys.argv[1], int(sys.argv[2])
with open(path, "rb") as f:
    data = f.read()
marker = b"\n[truncated=true]"
cut = max(limit - len(marker), 0)
while cut > 0 and (data[cut] & 0xC0) == 0x80:
    cut -= 1
with open(path, "wb") as f:
    f.write(data[:cut] + marker)
PYEOF
    PAYLOAD_CHARS="$(wc -c < "${PAYLOAD_FILE}" | tr -d ' ')"
fi
_PAYLOAD_CHARS="${PAYLOAD_CHARS}"

# xtrace scoping: the webhook URL is secret-mounted, and both the read
# and the presence test would trace its value (test arguments are traced
# expanded).
{ set +x; } 2>/dev/null
WEBHOOK_URL=""
if [ -s "${ANALYZER_WEBHOOK_FILE}" ]; then
    WEBHOOK_URL="$(cat "${ANALYZER_WEBHOOK_FILE}")"
fi
_WEBHOOK_PRESENT=0
[ -n "${WEBHOOK_URL}" ] && _WEBHOOK_PRESENT=1
{ set -x; } 2>/dev/null
SINK_STATUS_FILE="$(mktemp /tmp/prow-analyzer-sink.XXXXXX)"
_CLEANUP_FILES+=("${SINK_STATUS_FILE}")
SINK_RC=0
if [ "${_WEBHOOK_PRESENT}" -eq 0 ]; then
    SINK_RC=99
else
    { set +x; } 2>/dev/null
    OPP_SINK_WEBHOOK_URL="${WEBHOOK_URL}" \
    python3 - "$PAYLOAD_FILE" "$SINK_STATUS_FILE" <<'PYEOF' || SINK_RC=$?
import json, os, sys, urllib.request
payload_file, status_file = sys.argv[1], sys.argv[2]
url = os.environ["OPP_SINK_WEBHOOK_URL"]
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
    { set -x; } 2>/dev/null
fi

# sink_status on the terminal line makes the delivery outcome attributable
# from public artifacts: a bare outcome=sink_error cannot distinguish a
# missing webhook file from an HTTP rejection or a transport failure
# (INTEROP-9648 follow-up from the #88323 combined rehearsal,
# 2118352372378898432).
if [ "${SINK_RC}" -eq 0 ]; then
    _SINK_STATUS="$(cat "${SINK_STATUS_FILE}" || echo 0)"
    printf '%s:%s\n' "${BUILD_ID}" "${RESPONSE_SHA}" >> "${ANALYZER_STATE_FILE}"
elif [ "${SINK_RC}" -eq 99 ]; then
    _OUTCOME="sink_error"; _GATE="webhook_url_absent"; _SINK_STATUS="absent"
else
    _SINK_STATUS="$(cat "${SINK_STATUS_FILE}" || echo 0)"
    case "${_SINK_STATUS}" in
        2*|0) _OUTCOME="sink_error" ;;
        4*) if [ "${_SINK_STATUS}" = "429" ]; then _OUTCOME="sink_error"; else _OUTCOME="sink_rejected"; fi ;;
        *) _OUTCOME="sink_error" ;;
    esac
fi

exit 0
