#!/bin/bash
# interop-opp-slack-reporter step wrapper (INTEROP-9627).
# Canonical source: this repo, tools/slack_reporter_step/; delivered to
# openshift/release as ci-operator/step-registry/interop/opp/slack-reporter/
# interop-opp-slack-reporter-commands.sh. Design authority:
# docs/design/opp-slack-reporter-step.md.
#
# Lane-neutral best-effort post step: exits 0 on every graceful path.
# Emits a stage-tagged versioned result line (exactly one stage=terminal);
# emits NO JUnit ever. Shell tracing is OFF for the whole script; no env
# dumps; the webhook credential is read from its mounted file by the
# embedded delivery program only — never argv, never export.
#
# The JUnit parser below is GENERATED from src/opp_interop/junit.py by
# embed.py between the sentinels; regenerate, never hand-edit. The
# generated module must stay the FIRST code in its heredoc program
# (its `from __future__ import annotations` is only legal at program
# top). shopt patsub_replacement is explicitly OFF: bash >= 5.2 expands
# `&` in ${var/pat/repl} replacements (docs/design/step-registry-patterns
# section 4), and no string munging may happen in bash anyway.

shopt -u patsub_replacement
set -uo pipefail

# ------------------------------------------------- constants (reporter-owned)
# Provenance classes (design doc section 5): repo-mirrored values are
# byte-drift-gated inside the generated region below; reporter-owned
# values are unit-asserted with this script as the authority; generated
# artifacts are `regenerate == committed` via embed.py --check.
OPP_SLACK_REPORTER_PREFIX="OPP-SLACK-REPORTER"
OPP_SLACK_REPORTER_VERSION=1
SLACK_TEXT_FIELD="${SLACK_TEXT_FIELD:-text}"
SLACK_REPORTER_TEXT_CAP=40000          # chars of composed text (Slack limit)
SLACK_REPORTER_BODY_MAX_BYTES=131072   # serialized payload (MAX_ARG_STRLEN)
SLACK_REPORTER_SCAN_DEADLINE="${SLACK_REPORTER_SCAN_DEADLINE:-120}"
SLACK_REPORTER_HTTP_CONNECT_TIMEOUT="${SLACK_REPORTER_HTTP_CONNECT_TIMEOUT:-10}"
SLACK_REPORTER_HTTP_READ_TIMEOUT="${SLACK_REPORTER_HTTP_READ_TIMEOUT:-30}"
SLACK_REPORTER_BACKOFF_SECONDS="${SLACK_REPORTER_BACKOFF_SECONDS:-5}"
SLACK_REPORTER_RETRY_AFTER_CAP="${SLACK_REPORTER_RETRY_AFTER_CAP:-30}"
SLACK_REPORTER_MAX_ATTEMPTS="${SLACK_REPORTER_MAX_ATTEMPTS:-2}"
SLACK_REPORTER_RESERVE_SECONDS="${SLACK_REPORTER_RESERVE_SECONDS:-20}"
SLACK_REPORTER_WEBHOOK_FILE="${SLACK_REPORTER_WEBHOOK_FILE:-/tmp/secrets/opp-discussion-webhook/url}"

# ------------------------------------------------- generated role table
# The step-role table (design doc section 5) is GENERATED from the wired
# configs + step registry + fixture observations by generate_role_table.py
# and embedded here as a compact JSON literal; regenerate, never hand-edit.
# Runtime override is a TEST SEAM only: SLACK_REPORTER_ROLE_TABLE_OVERRIDE
# is honored solely with SLACK_REPORTER_TEST_SEAM=1 and never when
# JOB_TYPE=periodic. A job-name miss renders every dir unrecognized
# (UNVERIFIED, reason role_table_miss:<job>) — never green.
# ---- BEGIN GENERATED: role_table ----
OPP_SLACK_REPORTER_ROLE_TABLE='{"periodic-ci-RedHatQE-interop-testing-master-ocp-4.22-lpMainline-lp-interop--opp-cr--full-stack--aws":{"acm-fetch-managed-clusters":"test-best-effort","acm-fetch-operator-versions":"post-phase","acm-inspector":"post-phase","acm-mch":"post-phase","acm-opp-app":"test-best-effort","acm-policies-openshift-plus":"post-phase","acm-policies-openshift-plus-setup":"post-phase","acm-tests-clc-destroy":"post-phase","acm-tests-clc-smoke":"test-best-effort","firewatch-report-issues":"post-phase","install-operators":"post-phase","interop-opp-disk-diag":"post-phase","interop-opp-kubelet-config":"post-phase","interop-opp-odf-health":"test-authoritative","interop-opp-skip-ratio-gate":"post-phase","interop-opp-slack-reporter":"own","interop-opp-wait-for-api":"post-phase","interop-opp-wait-mcp":"test-authoritative","interop-tests-ocs-tests":"test-best-effort","interop-tests-opp-quay-smoke":"test-best-effort","ipi-conf":"post-phase","ipi-conf-aws":"post-phase","ipi-conf-aws-custom-az":"post-phase","ipi-conf-aws-rootvolume":"post-phase","ipi-conf-telemetry":"post-phase","ipi-deprovision-deprovision":"post-phase","ipi-install-hosted-loki":"post-phase","ipi-install-install":"post-phase","ipi-install-monitoringpvc":"post-phase","ipi-install-rbac":"post-phase","ipi-install-times-collection":"post-phase","mpiit-data-router-reporter":"post-phase","multiarch-validate-nodes":"post-phase","nodes-readiness":"post-phase","openshift-cluster-bot-rbac":"post-phase","openshift-tests-extension-admission-crd-install":"post-phase","stackrox-opp-readiness":"test-best-effort","stackrox-opp-smoke":"test-best-effort"},"periodic-ci-RedHatQE-interop-testing-master-ocp-5.0-lpMainline-lp-interop--opp-cr--full-stack--aws":{"acm-fetch-managed-clusters":"test-best-effort","acm-fetch-operator-versions":"post-phase","acm-inspector":"post-phase","acm-mch":"post-phase","acm-opp-app":"test-best-effort","acm-policies-openshift-plus":"post-phase","acm-policies-openshift-plus-setup":"post-phase","acm-tests-alc":"post-phase","acm-tests-clc-create":"post-phase","acm-tests-clc-destroy":"post-phase","acm-tests-clc-smoke":"test-best-effort","acm-tests-grc":"post-phase","firewatch-report-issues":"post-phase","install-operators":"post-phase","interop-opp-odf-health":"test-authoritative","interop-opp-skip-ratio-gate":"post-phase","interop-opp-slack-reporter":"own","interop-opp-wait-mcp":"test-authoritative","interop-tests-opp-quay-smoke":"test-best-effort","ipi-conf":"post-phase","ipi-conf-aws":"post-phase","ipi-conf-aws-custom-az":"post-phase","ipi-conf-telemetry":"post-phase","ipi-deprovision-deprovision":"post-phase","ipi-install-hosted-loki":"post-phase","ipi-install-install":"post-phase","ipi-install-monitoringpvc":"post-phase","ipi-install-rbac":"post-phase","ipi-install-times-collection":"post-phase","mpiit-data-router-reporter":"post-phase","multiarch-validate-nodes":"post-phase","nodes-readiness":"post-phase","openshift-cluster-bot-rbac":"post-phase","openshift-tests-extension-admission-crd-install":"post-phase","stackrox-opp-readiness":"test-best-effort","stackrox-opp-smoke":"test-best-effort"},"periodic-ci-RedHatQE-interop-testing-master-ocp-5.0-lpMainline-lp-interop--opp-full-stack--fips--aws":{"acm-fetch-managed-clusters":"test-best-effort","acm-fetch-operator-versions":"post-phase","acm-inspector":"post-phase","acm-mch":"post-phase","acm-opp-app":"test-best-effort","acm-policies-openshift-plus":"post-phase","acm-policies-openshift-plus-setup":"post-phase","acm-tests-alc":"post-phase","acm-tests-clc-create":"post-phase","acm-tests-clc-destroy":"post-phase","acm-tests-clc-smoke":"test-best-effort","acm-tests-grc":"post-phase","firewatch-report-issues":"post-phase","install-operators":"post-phase","interop-opp-odf-health":"test-authoritative","interop-opp-slack-reporter":"own","interop-opp-wait-mcp":"test-authoritative","interop-tests-opp-quay-smoke":"test-best-effort","ipi-conf":"post-phase","ipi-conf-aws":"post-phase","ipi-conf-aws-custom-az":"post-phase","ipi-conf-telemetry":"post-phase","ipi-deprovision-deprovision":"post-phase","ipi-install-hosted-loki":"post-phase","ipi-install-install":"post-phase","ipi-install-monitoringpvc":"post-phase","ipi-install-rbac":"post-phase","ipi-install-times-collection":"post-phase","multiarch-validate-nodes":"post-phase","nodes-readiness":"post-phase","openshift-cluster-bot-rbac":"post-phase","openshift-tests-extension-admission-crd-install":"post-phase","stackrox-opp-readiness":"test-best-effort","stackrox-opp-smoke":"test-best-effort"},"periodic-ci-RedHatQE-interop-testing-master-ocp-5.1-lpMainline-lp-interop--opp-cr--full-stack--aws":{"acm-fetch-managed-clusters":"test-best-effort","acm-fetch-operator-versions":"post-phase","acm-inspector":"post-phase","acm-mch":"post-phase","acm-opp-app":"test-best-effort","acm-policies-openshift-plus":"post-phase","acm-policies-openshift-plus-setup":"post-phase","acm-tests-alc":"post-phase","acm-tests-clc-create":"post-phase","acm-tests-clc-destroy":"post-phase","acm-tests-clc-smoke":"test-best-effort","acm-tests-grc":"post-phase","firewatch-report-issues":"post-phase","install-operators":"post-phase","interop-opp-skip-ratio-gate":"post-phase","interop-opp-slack-reporter":"own","interop-opp-wait-mcp":"test-authoritative","interop-tests-opp-quay-smoke":"test-best-effort","ipi-conf":"post-phase","ipi-conf-aws":"post-phase","ipi-conf-aws-custom-az":"post-phase","ipi-conf-telemetry":"post-phase","ipi-deprovision-deprovision":"post-phase","ipi-install-hosted-loki":"post-phase","ipi-install-install":"post-phase","ipi-install-monitoringpvc":"post-phase","ipi-install-rbac":"post-phase","ipi-install-times-collection":"post-phase","mpiit-data-router-reporter":"post-phase","multiarch-validate-nodes":"post-phase","nodes-readiness":"post-phase","openshift-cluster-bot-rbac":"post-phase","openshift-tests-extension-admission-crd-install":"post-phase","stackrox-opp-readiness":"test-best-effort","stackrox-opp-smoke":"test-best-effort"},"periodic-ci-RedHatQE-interop-testing-master-ocp-5.1-lpMainline-lp-interop--opp-full-stack--fips--aws":{"acm-fetch-managed-clusters":"test-best-effort","acm-fetch-operator-versions":"post-phase","acm-inspector":"post-phase","acm-mch":"post-phase","acm-opp-app":"test-best-effort","acm-policies-openshift-plus":"post-phase","acm-policies-openshift-plus-setup":"post-phase","acm-tests-alc":"post-phase","acm-tests-clc-create":"post-phase","acm-tests-clc-destroy":"post-phase","acm-tests-clc-smoke":"test-best-effort","acm-tests-grc":"post-phase","firewatch-report-issues":"post-phase","install-operators":"post-phase","interop-opp-slack-reporter":"own","interop-opp-wait-mcp":"test-authoritative","interop-tests-opp-quay-smoke":"test-best-effort","ipi-conf":"post-phase","ipi-conf-aws":"post-phase","ipi-conf-aws-custom-az":"post-phase","ipi-conf-telemetry":"post-phase","ipi-deprovision-deprovision":"post-phase","ipi-install-hosted-loki":"post-phase","ipi-install-install":"post-phase","ipi-install-monitoringpvc":"post-phase","ipi-install-rbac":"post-phase","ipi-install-times-collection":"post-phase","multiarch-validate-nodes":"post-phase","nodes-readiness":"post-phase","openshift-cluster-bot-rbac":"post-phase","openshift-tests-extension-admission-crd-install":"post-phase","stackrox-opp-readiness":"test-best-effort","stackrox-opp-smoke":"test-best-effort"}}'
# ---- END GENERATED: role_table ----

# ------------------------------------------------------------------ state
_TERMINAL_EMITTED=0
_STATE="UNVERIFIED"
_REASON="in_progress"

emit_skeleton() {
    printf '%s\n' "${OPP_SLACK_REPORTER_PREFIX} v=${OPP_SLACK_REPORTER_VERSION} stage=skeleton state=${_STATE} reason=${_REASON}"
}

emit_terminal() {
    # Exactly one terminal line is ever emitted (design doc section 10):
    # either the embedded program emits it (and touches the sent file) or
    # this fallback does — never both.
    if [ "${_TERMINAL_EMITTED}" -eq 1 ] || [ -e "${_SENT_FILE}" ]; then
        return 0
    fi
    _TERMINAL_EMITTED=1
    printf '%s\n' "${OPP_SLACK_REPORTER_PREFIX} v=${OPP_SLACK_REPORTER_VERSION} stage=terminal state=${_STATE} reason=${_REASON}"
}

on_term() {
    _REASON="scan_interrupted"
}
trap on_term TERM INT

on_exit() {
    emit_terminal
    exit 0
}
trap on_exit EXIT

# The sent file coordinates single emission across bash and the embedded
# python programs (mktemp dir per invocation; the marker file itself is
# created ONLY at emission time — never at setup).
_SENT_DIR="$(mktemp -d)" 2>/dev/null || _SENT_DIR="/tmp/opp-slack-reporter-$$"
mkdir -p "${_SENT_DIR}"
_SENT_FILE="${_SENT_DIR}/sent"
rm -f "${_SENT_FILE}" 2>/dev/null || true
export OPP_SLACK_REPORTER_SENT_FILE="${_SENT_FILE}"

# ------------------------------------------------- generated JUnit parser
# One heredoc program; the generated module is the program's first code
# (see header note). The glue after the END sentinel is hand-written.
# ------------------------------------------------- embedded program
# ONE heredoc program: the generated parser is its first code (see
# header note); the glue after the END sentinel implements marker
# reading, the bounded scan, classification, and the selfcheck modes.
# argv[1] is always the embedded role table; argv[2:] selects the mode.
run_embedded_python() {
    python3 - "${OPP_SLACK_REPORTER_ROLE_TABLE}" "$@" <<'PY_OPP_JUNIT_EMBED'
# ---- BEGIN GENERATED: opp_interop.junit ----
"""JUnit XML parsing for OPP interop evidence.

Single parse point for JUnit XML in this repository: the migrated hub tool
``tools/opp_run_snapshot.py`` imports this module rather than keeping its
own copy, so gate decisions and run snapshots can never disagree about how
a JUnit file is read (ADR 0005 anticipated a separate parser module feeding
the same summary model).

Design contract: see ``docs/design/evidence-summarization.md``. Parsing is
pure and offline: given the same bytes, the parse result is identical. The
parser refuses documents containing DTDs or entity declarations (an XML
external-entity vector) and enforces a size cap; both refusals are reported
as structured errors, never exceptions.
"""

from __future__ import annotations

import hashlib
import xml.etree.ElementTree as ET
from dataclasses import dataclass, field

MAX_JUNIT_BYTES = 4_000_000
JUNIT_PARSER = "opp_interop.junit.parse_junit"
JUNIT_PARSER_VERSION = 3

_FORBIDDEN_MARKERS = (b"<!DOCTYPE", b"<!ENTITY")

#: Per-case outcome vocabulary. ``error`` is distinct from ``failed``:
#: a JUnit ``<error>`` means the test could not run (or the harness
#: errored), not that an assertion failed. Both are failures for gating.
CASE_PASSED = "passed"
CASE_FAILED = "failed"
CASE_ERROR = "error"
CASE_SKIPPED = "skipped"


@dataclass(frozen=True)
class JunitCase:
    """One testcase with its resolved outcome and first marker message."""

    name: str | None
    classname: str | None
    case_id: str | None
    outcome: str
    markers: tuple[str, ...] = ()
    message: str | None = None


@dataclass(frozen=True)
class JunitResult:
    """Structured parse of one JUnit document (or a structured refusal)."""

    source_url: str
    complete: bool
    error: str | None = None
    content_bytes: int = 0
    raw_sha256: str = ""
    testcase_count: int = 0
    cases: list[JunitCase] = field(default_factory=list)
    parser: dict[str, object] = field(
        default_factory=lambda: {"name": JUNIT_PARSER, "version": JUNIT_PARSER_VERSION}
    )

    @property
    def counts(self) -> dict[str, int]:
        """Counts by outcome, computed from per-case outcomes.

        Counting per case (not per marker) keeps the summary consistent
        when one testcase carries multiple markers.
        """
        return {
            outcome: sum(1 for case in self.cases if case.outcome == outcome)
            for outcome in (CASE_FAILED, CASE_ERROR, CASE_SKIPPED)
        }


def parse_junit(data: bytes, source_url: str) -> JunitResult:
    """Parse JUnit XML bytes into a :class:`JunitResult`.

    Refusals (size cap, DTD/entity presence, invalid XML, wrong root tag)
    return ``complete=False`` with a structured ``error`` string; the
    function never raises for bad input.
    """
    raw_sha256 = hashlib.sha256(data).hexdigest()
    if len(data) > MAX_JUNIT_BYTES:
        return _refusal(source_url, len(data), raw_sha256, "junit_size_limit")
    head = data[:4096]
    if any(marker in head for marker in _FORBIDDEN_MARKERS):
        return _refusal(source_url, len(data), raw_sha256, "junit_dtd_or_entity_forbidden")
    try:
        root = ET.fromstring(data)
    except (ET.ParseError, ValueError):
        return _refusal(source_url, len(data), raw_sha256, "junit_xml_invalid")
    if root.tag not in {"testsuite", "testsuites"}:
        return _refusal(source_url, len(data), raw_sha256, "junit_root_invalid")

    cases: list[JunitCase] = []
    for element in root.iter("testcase"):
        markers: list[tuple[str, ET.Element]] = []
        for tag in ("failure", "error", "skipped"):
            node = element.find(tag)
            if node is not None:
                markers.append((tag, node))
        # First matching marker wins (matches the migrated hub parser's
        # documented abnormal-outcome interpretation). Tag names map to the
        # outcome vocabulary: failure -> failed, error -> error, skipped -> skipped.
        _TAG_TO_OUTCOME = {"failure": CASE_FAILED, "error": CASE_ERROR, "skipped": CASE_SKIPPED}
        outcome = _TAG_TO_OUTCOME[markers[0][0]] if markers else CASE_PASSED
        message = None
        if markers:
            node = markers[0][1]
            message = (node.get("message") or (node.text or "")).strip() or None
        cases.append(
            JunitCase(
                name=element.get("name"),
                classname=element.get("classname"),
                case_id=element.get("id"),
                outcome=outcome,
                markers=tuple(tag for tag, _ in markers),
                message=message,
            )
        )
    return JunitResult(
        source_url=source_url,
        complete=True,
        content_bytes=len(data),
        raw_sha256=raw_sha256,
        testcase_count=len(cases),
        cases=cases,
    )


def _refusal(source_url: str, content_bytes: int, raw_sha256: str, error: str) -> JunitResult:
    return JunitResult(
        source_url=source_url,
        complete=False,
        error=error,
        content_bytes=content_bytes,
        raw_sha256=raw_sha256,
    )


def compare_version_tuples(left: str, right: str) -> int:
    """Compare two dotted version strings numerically.

    Returns negative when ``left < right``, ``0`` when equal, positive when
    ``left > right``. Missing components count as ``0`` so ``4.10`` equals
    ``4.10.0``. Lexicographic pitfalls (``4.9`` vs ``4.10``) are avoided;
    the same rule must be mirrored by any shell-side comparator (see the
    design doc's change rules).
    """

    def parts(value: str) -> list[int]:
        value = value.strip()
        while value and not value[0].isdigit():
            value = value[1:]
        numeric: list[int] = []
        for piece in value.strip().split("."):
            digits = ""
            for char in piece:
                if char.isdigit():
                    digits += char
                else:
                    break
            numeric.append(int(digits) if digits else 0)
        return numeric or [0]

    left_parts, right_parts = parts(left), parts(right)
    length = max(len(left_parts), len(right_parts))
    left_parts += [0] * (length - len(left_parts))
    right_parts += [0] * (length - len(right_parts))
    if left_parts < right_parts:
        return -1
    if left_parts > right_parts:
        return 1
    return 0
# ---- END GENERATED: opp_interop.junit ----
# ------------------------------------------------------------------ glue
# Marker reading, bounded scan, classification, selfcheck modes (not
# generated). One terminal result line, ever: the sent file is touched
# immediately before printing it so the bash fallback cannot duplicate.
import json
import os
import re
import signal
import stat
import sys
import time

ROLE_TABLE_TEXT = sys.argv[1]
ARGS = sys.argv[2:]
MODE = ARGS[0] if ARGS else 'scan'

PREFIX = 'OPP-SLACK-REPORTER'
VERSION = 1
STATES = ('PASS', 'PASS_WITH_FAILURES', 'UNVERIFIED', 'FAIL', 'CONFIG_ERROR')
PRUNE_RE = re.compile(r'(gather|must-gather)', re.IGNORECASE)
JUNIT_NAME_RE = re.compile(r'^(junit_|test-)', re.IGNORECASE)
TEST_PHASE_ROLES = ('test-authoritative', 'test-best-effort')
MAX_SCAN_ENTRIES = 200
MAX_SCAN_DEPTH = 6

_INTERRUPTED = {'flag': False}


def _on_term(_signum, _frame):
    _INTERRUPTED['flag'] = True


signal.signal(signal.SIGTERM, _on_term)
signal.signal(signal.SIGINT, _on_term)


# ----------------------------------------------------------- output
_SAFE_CHAR = re.compile(r'[^A-Za-z0-9._=-]')


def esc(value):
    """Escape helper for EVERY interpolated value (design doc section 10):
    allow [A-Za-z0-9._=-]; %xx-encode everything else — no CR/LF, no
    forged fields, one line."""
    out = []
    for ch in str(value):
        if _SAFE_CHAR.match(ch):
            out.append('%%%02X' % ord(ch))
        else:
            out.append(ch)
    return ''.join(out)


def emit_terminal_line(state, test, tallies, delivered, http, reasons):
    sent = os.environ.get('OPP_SLACK_REPORTER_SENT_FILE', '')
    if sent:
        try:
            with open(sent, 'w') as handle:
                handle.write('1')
        except OSError:
            pass
    reason = ';'.join(sorted(set(str(r) for r in reasons))) or 'none'
    print('%s v=%d stage=terminal state=%s test=%s '
          'tallies=failed=%d,errored=%d,skipped=%d delivered=%s http=%s '
          'reason=%s' % (
              PREFIX, VERSION, state, esc(test),
              tallies.get('failed', 0), tallies.get('error', 0),
              tallies.get('skipped', 0), delivered, http, esc(reason)))


# ------------------------------------------------------ role table
def resolve_role_table():
    """(table, sha256, source, failure) — failure is None or (state, reason)."""
    import hashlib
    override = os.environ.get('SLACK_REPORTER_ROLE_TABLE_OVERRIDE', '')
    table_text = ROLE_TABLE_TEXT
    table_bytes = ROLE_TABLE_TEXT.encode('utf-8')
    source = 'embedded'
    if override:
        if os.environ.get('SLACK_REPORTER_TEST_SEAM') != '1':
            return None, None, 'embedded', ('CONFIG_ERROR',
                                            'role_table_override_refused')
        if os.environ.get('JOB_TYPE', '') == 'periodic':
            return None, None, 'embedded', ('CONFIG_ERROR',
                                            'role_table_override_refused_periodic')
        table_text = override
        table_bytes = override.encode('utf-8')
        source = 'override'
    try:
        table = json.loads(table_text)
    except ValueError:
        return None, None, source, ('CONFIG_ERROR', 'role_table_invalid')
    digest = hashlib.sha256(table_bytes).hexdigest()
    return table, digest, source, None


# ------------------------------------------------------ marker rule
def read_marker(step_dir):
    """(marker_or_None, anomaly_or_None) for <step_dir>/finished.json.

    Verbatim stepstatus alignment: uppercase SUCCESS; passed optional
    (null = absent, isinstance(bool) guard); contradiction refused;
    unparseable = partial_json; unreadable = OS failure."""
    path = os.path.join(step_dir, 'finished.json')
    try:
        info = os.lstat(path)
    except OSError:
        return None, None
    if stat.S_ISLNK(info.st_mode):
        return None, 'marker_anomaly:unreadable'
    try:
        with open(path, 'rb') as handle:
            raw = handle.read(1 << 20)
        value = json.loads(raw)
    except (OSError, ValueError):
        return None, 'marker_anomaly:partial_json'
    if not isinstance(value, dict):
        return None, 'marker_anomaly:not_object'
    result = value.get('result')
    if result not in ('SUCCESS', 'FAILURE', 'ABORTED'):
        return None, 'marker_anomaly:unknown_result'
    passed = value.get('passed')
    if passed is not None:
        if not isinstance(passed, bool):
            return None, 'marker_anomaly:non_boolean_passed'
        consistent = passed if result == 'SUCCESS' else not passed
        if not consistent:
            return None, 'marker_anomaly:contradiction'
    return {'result': result, 'passed': passed}, None


# ------------------------------------------------------ file safety
class SafeAccess:
    """Per-file safety: lstat, S_ISLNK refusal, realpath containment,
    /tmp/secrets and $SHARED_DIR exclusions (design doc section 6)."""

    def __init__(self, root):
        self.root = os.path.realpath(root)
        excludes = ['/tmp/secrets']
        shared = os.environ.get('SHARED_DIR', '')
        if shared:
            excludes.append(shared)
        self.excludes = [os.path.realpath(p) for p in excludes if p]

    def check(self, path):
        """(ok, refusal_reason) for one file about to be opened."""
        try:
            info = os.lstat(path)
        except OSError:
            return False, 'missing'
        if stat.S_ISLNK(info.st_mode):
            return False, 'symlink_escape:%s' % os.path.basename(path)
        real = os.path.realpath(path)
        if real != self.root and not real.startswith(self.root + os.sep):
            return False, 'symlink_escape:%s' % os.path.basename(path)
        for exclude in self.excludes:
            if real == exclude or real.startswith(exclude + os.sep):
                return False, 'symlink_escape:%s' % os.path.basename(path)
        return True, None

    def read_capped(self, path, cap):
        """(data, None) or (None, refusal): stat-first, bounded cap+1 read."""
        try:
            size = os.stat(path).st_size
        except OSError:
            return None, 'unreadable'
        if size > cap:
            return None, 'junit_size_limit'
        try:
            with open(path, 'rb') as handle:
                data = handle.read(cap + 1)
        except OSError:
            return None, 'unreadable'
        if len(data) > cap:  # stat-then-grow race: bounded refusal
            return None, 'junit_size_limit'
        return data, None


# ------------------------------------------------------ scan
def scan(base, table, roles):
    """Walk the scan base (the test dir); returns the evidence record."""
    safe = SafeAccess(base)
    deadline = time.time() + int(
        os.environ.get('SLACK_REPORTER_SCAN_DEADLINE', '120') or 120)
    evidence = {
        'test': os.path.basename(base.rstrip('/')),
        'markers': {}, 'anomalies': [], 'junit': [], 'degraded': [],
        'unrecognized_dirs': [], 'pruned': [], 'role_dir_missing': [],
        'truncated': False, 'deadline': False, 'interrupted': False,
    }

    def junit_candidates(dir_path, depth=0, out=None, refusals=None):
        """Bounded recursive junit-shaped discovery under one step dir.
        JUnit-shaped symlinks are recorded as refusals, never skipped
        silently (design doc section 6)."""
        if out is None:
            out = []
        if refusals is None:
            refusals = []
        if depth > MAX_SCAN_DEPTH or len(out) >= MAX_SCAN_ENTRIES:
            return out, refusals
        try:
            entries = sorted(os.scandir(dir_path), key=lambda e: e.name)
        except OSError:
            return out, refusals
        if len(entries) > MAX_SCAN_ENTRIES:
            evidence['truncated'] = True
            entries = entries[:MAX_SCAN_ENTRIES]
        for entry in entries:
            if len(out) >= MAX_SCAN_ENTRIES:
                evidence['truncated'] = True
                break
            if entry.is_symlink():
                if (JUNIT_NAME_RE.match(entry.name)
                        and entry.name.lower().endswith('.xml')):
                    refusals.append('symlink_escape:%s' % entry.name)
                continue
            if entry.is_dir(follow_symlinks=False):
                if PRUNE_RE.search(entry.name):
                    continue
                junit_candidates(entry.path, depth + 1, out, refusals)
            elif (JUNIT_NAME_RE.match(entry.name)
                    and entry.name.lower().endswith('.xml')):
                out.append(entry.path)
        return out, refusals

    try:
        step_dirs = sorted(e.name for e in os.scandir(base)
                           if e.is_dir(follow_symlinks=False))
    except OSError:
        return evidence, 'CONFIG_ERROR', ['base_unresolvable']
    if len(step_dirs) > MAX_SCAN_ENTRIES:
        evidence['truncated'] = True
        step_dirs = step_dirs[:MAX_SCAN_ENTRIES]

    for step in step_dirs:
        if _INTERRUPTED['flag']:
            evidence['interrupted'] = True
            break
        if time.time() > deadline:
            evidence['truncated'] = True
            evidence['deadline'] = True
            break  # finish the step dir before descending: checked between
        step_path = os.path.join(base, step)
        dir_ok, dir_refusal = safe.check(step_path)
        if not dir_ok:
            evidence['degraded'].append({'file': step, 'reason': dir_refusal})
            evidence['anomalies'].append(dir_refusal)
            continue
        role = roles.get(step)
        marker, anomaly = read_marker(step_path)
        if anomaly:
            evidence['anomalies'].append('%s:%s' % (anomaly, step))
        if role is None:
            if PRUNE_RE.search(step):
                # pruned dir: shallow probe for failure evidence only
                probe_marker, _ = read_marker(step_path)
                candidates = []
                try:
                    probe_entries = list(os.scandir(step_path))
                except OSError:
                    probe_entries = []
                has_evidence = (
                    probe_marker is not None
                    and probe_marker['result'] in ('FAILURE', 'ABORTED'))
                for probe in probe_entries[:MAX_SCAN_ENTRIES]:
                    if JUNIT_NAME_RE.match(probe.name):
                        has_evidence = has_evidence or probe_marker is None
                        candidates.append(probe.name)
                evidence['pruned'].append({
                    'name': step, 'marker_result':
                        probe_marker['result'] if probe_marker else None,
                    'junit_candidates': candidates, 'evidence': has_evidence})
                continue
            # unrecognized closure: record regardless of marker state
            candidates, rogue_refusals = junit_candidates(step_path)
            for refusal in rogue_refusals:
                evidence['degraded'].append({'file': step, 'reason': refusal})
            candidates = [os.path.basename(c) for c in candidates][:8]
            has_artifacts = False
            try:
                has_artifacts = any(True for _ in os.scandir(step_path))
            except OSError:
                pass
            evidence['unrecognized_dirs'].append({
                'name': step,
                'marker_result': marker['result'] if marker else None,
                'junit_candidates': candidates, 'has_junit': bool(candidates),
                'has_artifacts': has_artifacts})
            continue
        evidence['markers'][step] = marker  # None = absent
        if role in TEST_PHASE_ROLES:
            candidates, refusals = junit_candidates(step_path)
            for refusal in refusals:
                evidence['degraded'].append(
                    {'file': '%s/%s' % (step, refusal), 'reason': refusal})
            for candidate in candidates:
                rel = os.path.relpath(candidate, base)
                ok, refusal = safe.check(candidate)
                if not ok:
                    if refusal not in ('missing',):
                        evidence['degraded'].append({'file': rel,
                                                     'reason': refusal})
                    continue
                data, refusal = safe.read_capped(candidate, MAX_JUNIT_BYTES)
                if data is None:
                    evidence['degraded'].append({
                        'file': rel, 'reason': refusal,
                        'size': os.stat(candidate).st_size
                        if refusal == 'junit_size_limit' else None})
                    continue
                parsed = parse_junit(data, 'file://' + rel)
                evidence['junit'].append({
                    'file': rel, 'step': step,
                    'complete': parsed.complete, 'error': parsed.error,
                    'counts': parsed.counts if parsed.complete else None,
                    'testcase_count': parsed.testcase_count,
                    'raw_sha256': parsed.raw_sha256})
    # walk-completeness reconciliation (the table is an oracle)
    for step, role in roles.items():
        if role == 'own':
            continue
        if step not in step_dirs and step not in evidence['markers']:
            evidence['role_dir_missing'].append(step)
    return evidence, None, None


def harvest_enrichment(base, evidence, roles):
    """Bounded, boundary-validated link harvest from post-phase logs.

    LPINTEROP links (pinned redhat.atlassian.net form) and the
    ReportPortal launch_url; anything not matching the pinned shapes is
    dropped with an omitted-marker (design doc section 11)."""
    lpinterop_re = re.compile(
        r'https://redhat\.atlassian\.net/browse/(LPINTEROP-\d+)')
    launch_re = re.compile(r'https://\S*reportportal\S*/launch\S*',
                           re.IGNORECASE)
    links, launch, omitted = [], None, 0
    safe = SafeAccess(base)
    for step, role in roles.items():
        if role != 'post-phase':
            continue
        step_path = os.path.join(base, step)
        for name in ('build-log.txt', 'mpiit-data-router-reporter.log'):
            path = os.path.join(step_path, name)
            if not os.path.exists(path):
                continue
            ok, refusal = safe.check(path)
            if not ok:
                omitted += 1
                continue
            try:
                with open(path, 'rb') as handle:
                    data = handle.read(16384)
            except OSError:
                omitted += 1
                continue
            text = data.decode('utf-8', 'replace')
            for match in lpinterop_re.finditer(text):
                if match.group(0) not in links:
                    links.append(match.group(0))
            if launch is None:
                found = launch_re.search(text)
                if found:
                    launch = found.group(0)
    job = os.environ.get('JOB_NAME', '')
    build = os.environ.get('BUILD_ID', '')
    prow = ('https://prow.ci.openshift.org/view/gs/'
            'test-platform-results-public/logs/%s/%s' % (job, build)
            if job and build else None)
    return {'lpinterop': links[:8], 'launch_url': launch, 'prow_url': prow,
            'omitted': omitted}


# ------------------------------------------------------ classification
def classify(evidence, roles):
    """(state, reasons, tallies) — residual default UNVERIFIED, never PASS."""
    markers = evidence['markers']
    failed = lambda m: m is not None and m['result'] in ('FAILURE', 'ABORTED')
    tallies = {'failed': 0, 'error': 0, 'skipped': 0}
    seen_digests = {}
    for record in evidence['junit']:
        if record['complete']:
            seen_digests.setdefault(record['raw_sha256'], []).append(record)
    for digest, records in seen_digests.items():  # dedupe: counting only
        first = records[0]
        for outcome in tallies:
            tallies[outcome] += first['counts'][outcome]
    reasons = []

    # FAIL: authoritative failure, or failure inside an unrecognized dir
    fail_steps = sorted(step for step, m in markers.items()
                        if roles.get(step) == 'test-authoritative' and failed(m))
    unrecognized_failed = sorted(
        d['name'] for d in evidence['unrecognized_dirs']
        if d['marker_result'] in ('FAILURE', 'ABORTED'))
    if fail_steps or unrecognized_failed:
        for step in fail_steps:
            reasons.append('failed_steps:%s' % step)
        for step in unrecognized_failed:
            reasons.append('unrecognized_dir:%s' % step)
        return 'FAIL', reasons, tallies

    # PWF: positive failure evidence without an authoritative failure
    junit_red = tallies['failed'] + tallies['error'] > 0
    be_failed = sorted(step for step, m in markers.items()
                        if roles.get(step) in ('test-best-effort', 'post-phase')
                        and failed(m))
    if junit_red or be_failed:
        if junit_red:
            reasons.append('test_failures:%d' % tallies['failed'])
            reasons.append('test_errored:%d' % tallies['error'])
        for step in be_failed:
            reasons.append('failed_steps:%s' % step)
        return 'PASS_WITH_FAILURES', reasons, tallies

    # UNVERIFIED: every reason the evidence can carry
    test_phase = [s for s, r in roles.items() if r in TEST_PHASE_ROLES]
    readable = [r for r in evidence['junit'] if r['complete']]
    for anomaly in evidence['anomalies']:
        reasons.append(anomaly)
    for step in test_phase:
        marker = markers.get(step)
        if marker is None:
            reasons.append('marker_absent:%s' % step)
        elif marker['result'] == 'ABORTED':
            reasons.append('marker_aborted:%s' % step)
    if not readable:
        reasons.append('no_candidates' if not evidence['junit']
                       else 'all_refused')
    if readable and not any(
            r['testcase_count'] for r in readable):
        reasons.append('zero_testcase')
    for record in evidence['unrecognized_dirs']:
        if record['has_junit'] or (record['marker_result'] is None
                                   and record['has_artifacts']):
            reasons.append('unrecognized_dir:%s' % record['name'])
    for record in evidence['pruned']:
        if record['evidence']:
            reasons.append('pruned_dir:%s' % record['name'])
    for step in evidence['role_dir_missing']:
        reasons.append('role_dir_missing:%s' % step)
    for entry in evidence['degraded']:
        reasons.append(entry['reason'])
    if evidence['truncated']:
        reasons.append('scan_deadline' if evidence.get('deadline')
                       else 'truncated')
    if evidence['interrupted']:
        reasons.append('scan_interrupted')
    if reasons:
        return 'UNVERIFIED', reasons, tallies

    # PASS: the full conjunct, as the last branch
    authoritative = [s for s, r in roles.items()
                     if r == 'test-authoritative']
    for step in authoritative:
        marker = markers.get(step)
        if marker is None or marker['result'] != 'SUCCESS':
            reasons.append('marker_absent:%s' % step)
        elif not any(r['step'] == step and r['complete'] and r['testcase_count']
                     for r in readable):
            reasons.append('no_junit:%s' % step)
    observed_markers = [s for s in test_phase if markers.get(s) is not None]
    if not observed_markers:
        reasons.append('no_markers')
    if not readable:
        reasons.append('no_candidates')
    if not any(r['testcase_count'] for r in readable):
        reasons.append('zero_testcase')
    if evidence['truncated'] or evidence['degraded']:
        reasons.append('truncated' if evidence['truncated'] else 'degraded')
    if reasons:
        return 'UNVERIFIED', reasons, tallies
    return 'PASS', [], tallies


# ------------------------------------------------------ modes
def mode_junit_selfcheck():
    results = []
    for path in ARGS[1:]:
        with open(path, 'rb') as handle:
            data = handle.read()
        parsed = parse_junit(data, 'file://' + path)
        results.append({
            'file': path, 'complete': parsed.complete,
            'error': parsed.error, 'counts': parsed.counts,
            'testcase_count': parsed.testcase_count,
            'parser': parsed.parser})
    print(json.dumps(results))


def mode_role_table_selfcheck():
    table, digest, source, failure = resolve_role_table()
    report = {'source': source, 'job': os.environ.get('JOB_NAME', ''),
              'roles': None, 'miss': None, 'role_table_sha256': None,
              'state': None, 'reason': None}
    if table is None:
        report.update(state=failure[0], reason=failure[1])
        print(json.dumps(report, sort_keys=True))
        return
    report['role_table_sha256'] = digest
    job = report['job']
    if job not in table:
        report.update(miss='role_table_miss:' + job, state='UNVERIFIED')
        report['reason'] = report['miss']
    else:
        report['roles'] = table[job]
    print(json.dumps(report, sort_keys=True))


def mode_marker_selfcheck():
    """Differential seam: read_marker over each argv step dir."""
    results = []
    for path in ARGS[1:]:
        marker, anomaly = read_marker(path)
        results.append({'dir': path,
                        'result': marker['result'] if marker else None,
                        'passed': marker['passed'] if marker else None,
                        'anomaly': anomaly})
    print(json.dumps(results))


def mode_scan():
    artifact_dir = os.environ.get('ARTIFACT_DIR', '')
    if not artifact_dir:
        emit_terminal_line('CONFIG_ERROR', 'unknown', {}, '0', 'none',
                           ['artifact_dir_unset'])
        return
    base = os.environ.get('ARTIFACT_BASE_DIR') or os.path.join(
        artifact_dir, '..', '..')
    base = os.path.normpath(base)
    if not os.path.isdir(base):
        emit_terminal_line('CONFIG_ERROR', 'unknown', {}, '0', 'none',
                           ['base_unresolvable'])
        return
    table, digest, source, failure = resolve_role_table()
    if table is None:
        emit_terminal_line('CONFIG_ERROR', 'unknown', {}, '0', 'none',
                           [failure[1]])
        return
    job = os.environ.get('JOB_NAME', '')
    empty_evidence = {'test': os.path.basename(base), 'markers': {},
                      'anomalies': [], 'junit': [], 'degraded': [],
                      'unrecognized_dirs': [], 'pruned': [],
                      'role_dir_missing': [], 'truncated': False,
                      'interrupted': False}
    if job not in table:
        # job-name miss: every dir unrecognized => UNVERIFIED, never green
        evidence = empty_evidence
        roles = {}
        state = 'UNVERIFIED'
        reasons = ['role_table_miss:%s' % job]
        tallies = {'failed': 0, 'error': 0, 'skipped': 0}
    else:
        roles = table[job]
        evidence, config_state, config_reasons = scan(base, table, roles)
        if config_state == 'CONFIG_ERROR':
            emit_terminal_line('CONFIG_ERROR', evidence['test'], {}, '0',
                               'none', config_reasons)
            return
        state, reasons, tallies = classify(evidence, roles)
    counts_pass = (state == 'PASS' and tallies.get('skipped', 0) == 0)
    # run states defer the terminal line to the delivery program (the
    # only secret reader); CONFIG_ERROR paths above already emitted it
    report = {
        'state': state, 'test': evidence['test'], 'tallies': tallies,
        'skip_ratio': (round(tallies['skipped'] / (
            tallies['skipped'] + evidence.get('testcase_total', 0) or 1), 4)
            if tallies['skipped'] else None),
        'reason': reasons, 'degraded': evidence['degraded'],
        'unrecognized_dirs': evidence['unrecognized_dirs'],
        'pruned': evidence['pruned'], 'markers': {
            step: (m or {}).get('result') for step, m in
            evidence['markers'].items()},
        'junit': evidence['junit'], 'role_table_sha256': digest,
        'truncated': evidence['truncated'],
        'counts_as_pass_evidence': counts_pass,
        'enrichment': harvest_enrichment(base, evidence, roles) if roles
        else {'lpinterop': [], 'launch_url': None, 'prow_url': None,
              'omitted': 0},
        'parser': {'name': JUNIT_PARSER, 'version': JUNIT_PARSER_VERSION},
    }
    out_path = os.path.join(artifact_dir, 'slack-reporter.json')
    try:
        with open(out_path, 'w') as handle:
            json.dump(report, handle, indent=2, sort_keys=True)
    except OSError:
        pass  # observability is best-effort; delivery re-derives the line



if MODE == '--junit-selfcheck':
    mode_junit_selfcheck()
elif MODE == '--role-table-selfcheck':
    mode_role_table_selfcheck()
elif MODE == '--marker-selfcheck':
    mode_marker_selfcheck()
else:
    mode_scan()
PY_OPP_JUNIT_EMBED
}

# ------------------------------------------------- delivery program
# The ONLY secret reader. Receives nothing secret via argv or export:
# the webhook URL is read inside this program from the mounted file.
# Reads the scan report, composes the message (composition/escape/
# truncate/serialize/hash live HERE, never in bash), posts with the
# retry policy, and emits the terminal line (sent file => single
# emission across both programs and the bash fallback).
run_delivery_python() {
    python3 - <<'PY_OPP_DELIVERY_EMBED'
import hashlib
import json
import os
import re
import stat
import sys
import time
import urllib.error
import urllib.request

PREFIX = 'OPP-SLACK-REPORTER'
VERSION = 1
TEXT_CAP = int(os.environ.get('SLACK_REPORTER_TEXT_CAP', '40000'))
BODY_MAX_BYTES = 131072
FIELD = os.environ.get('SLACK_TEXT_FIELD', 'text')
WEBHOOK_FILE = os.environ.get(
    'SLACK_REPORTER_WEBHOOK_FILE',
    '/tmp/secrets/opp-discussion-webhook/url')
CONNECT_TIMEOUT = int(os.environ.get(
    'SLACK_REPORTER_HTTP_CONNECT_TIMEOUT', '10'))
READ_TIMEOUT = int(os.environ.get('SLACK_REPORTER_HTTP_READ_TIMEOUT', '30'))
BACKOFF = int(os.environ.get('SLACK_REPORTER_BACKOFF_SECONDS', '5'))
RETRY_AFTER_CAP = int(os.environ.get('SLACK_REPORTER_RETRY_AFTER_CAP', '30'))
MAX_ATTEMPTS = int(os.environ.get('SLACK_REPORTER_MAX_ATTEMPTS', '2'))
RESPONSE_CAP = 4096

#: accept-set (provisional until U1 records the observed webhook form;
#: asserted non-empty and fixture-matched by the matrix)
ACCEPT_SET = ('ok',)
REHEARSAL_TEXT = ('[interop-opp-slack-reporter] rehearsal verification '
                  'post — please disregard')

_SAFE_CHAR = re.compile(r'[^A-Za-z0-9._=-]')
_SECRET_SHAPED = re.compile(
    r'hooks\.slack\.com|/tmp/secrets|[A-Za-z0-9+/]{32,}')


def esc(value):
    out = []
    for ch in str(value):
        if _SAFE_CHAR.match(ch):
            out.append('%%%02X' % ord(ch))
        else:
            out.append(ch)
    return ''.join(out)


def emit_terminal_line(state, test, tallies, delivered, http, reasons):
    sent = os.environ.get('OPP_SLACK_REPORTER_SENT_FILE', '')
    if sent:
        try:
            with open(sent, 'w') as handle:
                handle.write('1')
        except OSError:
            pass
    reason = ';'.join(sorted(set(str(r) for r in reasons))) or 'none'
    print('%s v=%d stage=terminal state=%s test=%s '
          'tallies=failed=%d,errored=%d,skipped=%d delivered=%s http=%s '
          'reason=%s' % (
              PREFIX, VERSION, state, esc(test),
              tallies.get('failed', 0), tallies.get('error', 0),
              tallies.get('skipped', 0), delivered, http, esc(reason)))


def read_report():
    artifact_dir = os.environ.get('ARTIFACT_DIR', '')
    path = os.path.join(artifact_dir, 'slack-reporter.json')
    with open(path) as handle:
        return json.load(handle), path


def compose(report, rehearsal=False):
    """text = truncate(content, CAP - len(footer)) + footer; body =
    json.dumps({field: text}); payload_sha256 = sha256(content)."""
    if rehearsal:
        content = REHEARSAL_TEXT
    else:
        state = report['state'].replace('_', ' ')
        tallies = report['tallies']
        lines = ['[interop-opp-slack-reporter] %s' % state,
                 'test=%s' % report['test'],
                 'tallies failed=%d errored=%d skipped=%d' % (
                     tallies.get('failed', 0), tallies.get('error', 0),
                     tallies.get('skipped', 0))]
        if report['reason']:
            lines.append('reason %s' % ' '.join(report['reason']))
        enrichment = report.get('enrichment') or {}
        for link in enrichment.get('lpinterop') or []:
            lines.append(link)
        if enrichment.get('launch_url'):
            lines.append(enrichment['launch_url'])
        if enrichment.get('prow_url'):
            lines.append(enrichment['prow_url'])
        content = '\n'.join(lines)

    def footer_for(text_content):
        digest = hashlib.sha256(text_content.encode('utf-8')).hexdigest()
        return ('\n- interop-opp-slack-reporter v=%d payload_sha256=%s'
                % (VERSION, digest)), digest

    footer, digest = footer_for(content)
    if len(content) > TEXT_CAP - len(footer):
        content = content[:TEXT_CAP - len(footer)] + '...[truncated]'
        footer, digest = footer_for(content)
    text = content + footer
    body = json.dumps({FIELD: text})
    while len(body.encode('utf-8')) >= BODY_MAX_BYTES and content:
        content = content[:max(0, len(content) - 1000)] + '...[truncated]'
        footer, digest = footer_for(content)
        text = content + footer
        body = json.dumps({FIELD: text})
    assert len(text) <= TEXT_CAP
    assert len(body.encode('utf-8')) < BODY_MAX_BYTES
    return text, body, digest


def validate_url(url):
    """Full sibling predicate; returns None or a config_invalid reason.

    Under SLACK_REPORTER_TEST_SEAM=1 (test-only; the shipped ref.yaml
    never sets it — leak-scan asserted) a loopback http URL is accepted
    so the matrix can exercise the real posting path against the
    standin sink. The production predicate is unconditional."""
    if not isinstance(url, str) or not url:
        return 'config_invalid'
    if any(ch.isspace() for ch in url):
        return 'config_invalid'
    if os.environ.get('SLACK_REPORTER_TEST_SEAM') == '1' \
            and url.startswith('http://127.0.0.1:'):
        if len(url) <= 512:
            return None
        return 'config_invalid'
    if not url.startswith('https://hooks.slack.com/'):
        return 'config_invalid'
    if len(url) > 512:
        return 'config_invalid'
    path = url[len('https://hooks.slack.com/'):]
    if not (path.startswith('services/') or path.startswith('triggers/')
            or path.startswith('workflows/')):
        return 'config_invalid'
    return None


def load_secret():
    """(url, None) or (None, reason); mount hygiene enforced."""
    try:
        info = os.lstat(WEBHOOK_FILE)
    except OSError:
        return None, 'config_missing'
    if stat.S_ISLNK(info.st_mode):
        return None, 'config_invalid'
    if info.st_mode & 0o077:
        return None, 'config_invalid'
    try:
        with open(WEBHOOK_FILE) as handle:
            url = handle.read().strip()
    except OSError:
        return None, 'config_unreadable'
    reason = validate_url(url)
    if reason:
        return None, reason
    return url, None


def proc_secret_check(url):
    """The URL must appear in no cmdline/environ of this process."""
    for proc_file in ('/proc/self/cmdline', '/proc/self/environ'):
        try:
            with open(proc_file, 'rb') as handle:
                if url.encode('utf-8') in handle.read():
                    return False
        except OSError:
            continue
    return True


class _NoRedirect(urllib.request.HTTPRedirectHandler):
    def redirect_request(self, req, fp, code, msg, headers, newurl):
        return None


_OPENER = urllib.request.build_opener(_NoRedirect)


def post(url, body):
    """(delivered, http_code, outcome, diagnostics) per the retry policy:
    retry only on 429/5xx (<=1 retry, numeric Retry-After clamped,
    HTTP-date => configured backoff); transport exceptions are terminal
    delivery_unknown — never retried."""
    attempts = 0
    while attempts < MAX_ATTEMPTS:
        attempts += 1
        request = urllib.request.Request(
            url, data=body.encode('utf-8'), method='POST',
            headers={'Content-Type': 'application/json'})
        retry_after_raw = None
        try:
            with _OPENER.open(
                    request,
                    timeout=CONNECT_TIMEOUT + READ_TIMEOUT) as resp:
                status = resp.status
                retry_after_raw = resp.headers.get('Retry-After')
                data = resp.read(RESPONSE_CAP)
        except urllib.error.HTTPError as error:
            status = error.code
            retry_after_raw = error.headers.get('Retry-After') if \
                hasattr(error, 'headers') else None
            try:
                data = error.read(RESPONSE_CAP)
            except OSError:
                data = b''
        except (urllib.error.URLError, OSError, TimeoutError):
            return '0', '0', 'sink_error:delivery_unknown', {
                'attempts': attempts}
        if 200 <= status < 300:
            sanitized = data.decode('utf-8', 'replace').strip()
            if sanitized in ACCEPT_SET:
                return '1', str(status), 'delivered', {
                    'attempts': attempts, 'body_len': len(data)}
            token = re.sub(r'[^a-z0-9_]', '', sanitized[:24])
            return '0', str(status), 'sink_error', {
                'attempts': attempts, 'body_len': len(data),
                'body_token': token}
        if status == 429 or 500 <= status < 600:
            if attempts >= MAX_ATTEMPTS:
                return '0', str(status), 'sink_error', {
                    'attempts': attempts, 'body_len': len(data)}
            delay = BACKOFF
            if retry_after_raw and str(retry_after_raw).strip().isdigit():
                delay = min(RETRY_AFTER_CAP, int(retry_after_raw))
            time.sleep(delay)
            continue
        if 300 <= status < 400:
            return '0', str(status), 'sink_rejected', {
                'attempts': attempts}
        return '0', str(status), 'sink_rejected', {
            'attempts': attempts, 'body_len': len(data)}
    return '0', '0', 'sink_error', {'attempts': attempts}


def idempotency_key_path():
    job_type = os.environ.get('JOB_TYPE', '')
    job = os.environ.get('JOB_NAME', '')
    build = os.environ.get('BUILD_ID', '')
    if not job or not build:
        return None
    digest = hashlib.sha256(
        ('%s\0%s\0%s' % (job_type, job, build)).encode()).hexdigest()
    shared = os.environ.get('SHARED_DIR', '/tmp')
    return os.path.join(shared, 'interop-opp-slack-reporter-%s.key' % digest)


def write_dump(report, text):
    """Content allowlist: composed text, tallies, markers, reasons —
    never the URL, the secret, or raw response bytes."""
    dump = os.environ.get('SLACK_REPORTER_DUMP_FILE', '')
    if not dump:
        return None
    artifact_dir = os.environ.get('ARTIFACT_DIR', '')
    real_dump = os.path.realpath(dump)
    real_art = os.path.realpath(artifact_dir) if artifact_dir else ''
    if not real_art or (real_dump != real_art
                        and not real_dump.startswith(real_art + os.sep)):
        return 'config_invalid'
    payload = {
        'composed_text': text,
        'state': report['state'], 'test': report['test'],
        'tallies': report['tallies'], 'reason': report['reason'],
        'markers': report.get('markers'),
        'enrichment': report.get('enrichment'),
    }
    try:
        with open(dump, 'w') as handle:
            json.dump(payload, handle, indent=2, sort_keys=True)
    except OSError:
        return 'dump_unwritable'
    return None


def main():
    dry_run = os.environ.get('SLACK_REPORTER_DRY_RUN', '0') == '1'
    rehearsal = os.environ.get('SLACK_REPORTER_REHEARSAL_POST', '0') == '1'
    report, report_path = read_report()
    reasons = list(report['reason'] or [])
    tallies = report['tallies']
    delivered, http = '0', 'none'
    digest = None
    text = None
    delivery = {'outcome': 'not_attempted', 'attempts': 0}
    if dry_run:
        text, _body, digest = compose(report)
        reasons.append('dry_run')
        delivery.update(outcome='dry_run')
    else:
        url, secret_reason = load_secret()
        if url is None:
            reasons.append(secret_reason)
            delivery.update(outcome=secret_reason)
        elif rehearsal:
            nonce = os.path.join(os.path.dirname(WEBHOOK_FILE),
                                'rehearsal-nonce')
            if not os.path.exists(nonce):
                reasons.append('rehearsal_nonce_absent')
                delivery.update(outcome='rehearsal_nonce_absent')
            else:
                text, body, digest = compose(report, rehearsal=True)
                delivered, http, outcome, diag = post(url, body)
                reasons.append(outcome)
                delivery.update(outcome=outcome, **diag)
        else:
            key_path = idempotency_key_path()
            if key_path is None:
                reasons.append('idempotency_key_invalid')
                delivery.update(outcome='idempotency_key_invalid')
            elif os.path.exists(key_path):
                reasons.append('idempotent_skip')
                delivery.update(outcome='idempotent_skip')
            else:
                text, body, digest = compose(report)
                if _SECRET_SHAPED.search(text.rsplit('\n- interop-opp-'
                                                     'slack-reporter', 1)[0]):
                    reasons.append('delivery_blocked:secret_shaped_content')
                    delivery.update(
                        outcome='delivery_blocked:secret_shaped_content')
                else:
                    delivered, http, outcome, diag = post(url, body)
                    reasons.append(outcome)
                    delivery.update(outcome=outcome, **diag)
                    if delivered and key_path:
                        try:
                            with open(key_path, 'w') as handle:
                                handle.write(http)
                        except OSError:
                            pass
                    if url and not proc_secret_check(url):
                        reasons.append('secret_leak_suspected')
                        delivery['proc_leak_check'] = 'FAIL'
                    else:
                        delivery['proc_leak_check'] = 'ok'
    if os.environ.get('SLACK_REPORTER_DUMP_FILE') and text is not None:
        dump_error = write_dump(report, text)
        if dump_error:
            reasons.append(dump_error)
    report['delivery'] = delivery
    report['delivered'] = delivered
    report['http'] = http
    report['payload_sha256'] = digest
    try:
        with open(report_path, 'w') as handle:
            json.dump(report, handle, indent=2, sort_keys=True)
    except OSError:
        pass
    if delivery['outcome'] == 'delivered':
        reasons = [r for r in reasons if r != 'delivered']
    emit_terminal_line(report['state'], report['test'], tallies,
                       delivered, http, reasons)


main()
PY_OPP_DELIVERY_EMBED
}

main() {
    case "${1:-}" in
        --junit-selfcheck)
            shift
            run_embedded_python --junit-selfcheck "$@"
            ;;
        --role-table-selfcheck)
            run_embedded_python --role-table-selfcheck
            ;;
        --marker-selfcheck)
            shift
            run_embedded_python --marker-selfcheck "$@"
            ;;
        *)
            # job-type guard (production only; DRY_RUN is exempt — its
            # sole purpose is the probe)
            if [ "${SLACK_REPORTER_DRY_RUN:-0}" != "1" ] \
                    && [ "${JOB_TYPE:-}" != "periodic" ]; then
                _REASON="job_type_not_periodic"
                return 0
            fi
            run_embedded_python --scan || { _REASON="scan_crashed"; return 0; }
            if [ -e "${_SENT_FILE}" ]; then
                return 0  # CONFIG_ERROR already emitted its terminal line
            fi
            run_delivery_python || { _REASON="delivery_unknown"; return 0; }
            ;;
    esac
}

emit_skeleton
main "$@"
