#!/bin/bash

set -euo pipefail

export KUBECONFIG="${SHARED_DIR}/kubeconfig"

# Ansible requires Python, so it must be present in this image — fail fast if not.
PYTHON=$(command -v python3 || command -v python || true)
if [[ -z "${PYTHON}" ]]; then
  echo "ERROR: no python3 or python found in PATH" >&2
  exit 1
fi

# Load sensitive credentials from mounted secrets — disable tracing to prevent log exposure
[[ $- == *x* ]] && WAS_TRACING=true || WAS_TRACING=false
set +x

OCM_CLIENT_ID=$(cat /var/run/rosa-hcp-e2e-secrets/ocmClientID)
OCM_CLIENT_SECRET=$(cat /var/run/rosa-hcp-e2e-secrets/ocmClientSecret)
OCM_API_URL=$(cat /var/run/rosa-hcp-e2e-secrets/ocmApiUrl)
QUAY_USER=$(cat /var/run/rosa-hcp-e2e-secrets/quayUsername)
QUAY_PASS=$(cat /var/run/rosa-hcp-e2e-secrets/quayPassword)
AWS_ACCESS_KEY_ID=$(grep aws_access_key_id /var/run/rosa-e2e-aws-creds/awsEncodedCredentials | awk -F= '{print $2}' | tr -d ' ')
AWS_SECRET_ACCESS_KEY=$(grep aws_secret_access_key /var/run/rosa-e2e-aws-creds/awsEncodedCredentials | awk -F= '{print $2}' | tr -d ' ')
AWS_ACCOUNT_ID=$(cat /var/run/rosa-e2e-aws-creds/awsAccountId)
export OCM_CLIENT_ID OCM_CLIENT_SECRET OCM_API_URL AWS_ACCESS_KEY_ID AWS_SECRET_ACCESS_KEY AWS_ACCOUNT_ID
export QUAY_USER QUAY_PASS

$WAS_TRACING && set -x || true

# Clone rosa-hcp-e2e-test repository
WORK_DIR=$(mktemp -d)
echo "Cloning ${ROSA_HCP_E2E_REPO} (branch: ${ROSA_HCP_E2E_BRANCH})..."
git clone --depth=1 --branch "${ROSA_HCP_E2E_BRANCH}" "${ROSA_HCP_E2E_REPO}" "${WORK_DIR}/rosa-hcp-e2e-test"
cd "${WORK_DIR}/rosa-hcp-e2e-test"

# Install Python dependencies
if [[ -f "requirements.txt" ]]; then
  echo "Installing Python requirements..."
  "${PYTHON}" -m pip install -r requirements.txt
fi

# Install Ansible collection/role dependencies
if [[ -f "requirements.yml" ]]; then
  echo "Installing Ansible requirements..."
  ansible-galaxy install -r requirements.yml
fi

# Install jq
if ! command -v jq &>/dev/null; then
  echo "Installing jq..."
  JQ_SHA256="5942c9b0934e510ee61eb3e30273f1b3fe2590df93933a93d7c58b81d19c8ff5"
  mkdir -p /tmp/bin
  curl -fsSL --connect-timeout 30 --max-time 60 --retry 3 \
    "https://github.com/jqlang/jq/releases/download/jq-1.7.1/jq-linux-amd64" -o /tmp/bin/jq
  echo "${JQ_SHA256}  /tmp/bin/jq" | sha256sum --check --status || {
    echo "ERROR: jq checksum verification failed" >&2
    exit 1
  }
  chmod +x /tmp/bin/jq
  export PATH="/tmp/bin:$PATH"
  echo "jq installed: $(jq --version)"
else
  echo "jq already installed: $(jq --version)"
fi

# Install helm
if ! command -v helm &>/dev/null; then
  echo "Installing helm..."
  HELM_VERSION="3.17.3"
  HELM_SHA256="ee88b3c851ae6466a3de507f7be73fe94d54cbf2987cbaa3d1a3832ea331f2cd"
  HELM_ARCHIVE="helm-v${HELM_VERSION}-linux-amd64.tar.gz"
  curl -fsSL --connect-timeout 30 --max-time 120 --retry 3 \
    "https://get.helm.sh/${HELM_ARCHIVE}" -o "/tmp/${HELM_ARCHIVE}"
  echo "${HELM_SHA256}  /tmp/${HELM_ARCHIVE}" | sha256sum --check --status || {
    echo "ERROR: helm checksum verification failed" >&2
    exit 1
  }
  tar -xzf "/tmp/${HELM_ARCHIVE}" -C /tmp
  mkdir -p /tmp/bin
  mv /tmp/linux-amd64/helm /tmp/bin/helm
  chmod +x /tmp/bin/helm
  export PATH="/tmp/bin:$PATH"
  rm -rf "/tmp/${HELM_ARCHIVE}" "/tmp/${HELM_ARCHIVE}.sha256sum" /tmp/linux-amd64
  echo "Helm installed: $(helm version --short)"
else
  echo "Helm already installed: $(helm version --short)"
fi

# Export test env variables.
export DEPLOYMENT_MODE

# Generate a unique 4-char prefix per run to avoid IAM role name collisions
NAME_PREFIX="ci$(head -c 2 /dev/urandom | od -An -tx1 | tr -d ' ')"

EXTRA_VARS=("-e" "name_prefix=${NAME_PREFIX}")
if [[ -n "${OPENSHIFT_VERSION}" ]]; then
  EXTRA_VARS+=("-e" "openshift_version=${OPENSHIFT_VERSION}")
fi
if [[ -n "${CHANNEL_GROUP}" ]]; then
  EXTRA_VARS+=("-e" "channel_group=${CHANNEL_GROUP}")
fi
if [[ "${RESERVE_UPGRADE_PATH:-}" == "true" ]]; then
  EXTRA_VARS+=("-e" "reserve_upgrade_path=true")
fi
if [[ -n "${CLUSTER_API_INSTALLER_REF:-}" ]]; then
  EXTRA_VARS+=("-e" "cluster_api_installer_ref=${CLUSTER_API_INSTALLER_REF}")
fi

# Name of the structured result artifact.
SUMMARY_NAME="rosa-hcp-e2e-test-summary.json"

# Summarise the test runner's own reports into a publishable artifact.
#
# run-test-suite.py writes JSON, HTML and JUnit reports under test-results/
# whether the suite passed or failed, so the per-test outcomes already exist on
# disk - they are simply discarded with the container. They cannot be copied
# into ARTIFACT_DIR as they stand: every one of those reports embeds free-form
# material produced by the ansible run (failure messages, captured playbook
# stdout in <system-out>, playbook and feature names, local file paths), and
# ARTIFACT_DIR is published publicly. So nothing is copied. The helper reads the
# runner's JUnit report and republishes only integers and generated ordinals:
# how many testcases ran, and for each one whether it passed, failed, errored
# or was skipped. An ordinal is a position in the report and nothing more - it
# is not a key into rosa-hcp-e2e-test.log, whose console output does not
# enumerate testcases in the same granularity the JUnit report does.
#
# Run with -I: the working directory here is the test repository that was just
# cloned and pip installed into, and isolated mode is what keeps a module there
# - a json.py, an xml/ package - from shadowing a stdlib import of the helper.
export_structured_results() {
  local results_root=$1 summary_path=$2
  "${PYTHON}" -I - "${results_root}" "${summary_path}" <<'PYTHON_HELPER'
"""Summarise the rosa-hcp-e2e-test JUnit report into content-free results.

Reads the single JUnit report the runner leaves under <checkout>/test-results/
and writes a bounded JSON summary holding totals and one record per testcase,
up to MAX_CASES_RECORDED of them. A record carries a generated ordinal - its
position in the report, not a key into any other artifact - and an outcome
drawn from a fixed set. It never carries a name, a classname, a message, a
timestamp, a duration or a path, all of which are free-form text this step
does not control.

Every refusal is recorded as a fixed reason token in the summary itself and the
process still exits 0: this is diagnostics, and it must not be able to turn a
passing run into a failing one or the reverse.
"""

import json
import os
import stat
import sys
import xml.etree.ElementTree as ET

SCHEMA = 1
DIR_FLAGS = os.O_RDONLY | os.O_DIRECTORY | os.O_NOFOLLOW
# The runner writes exactly one dated JUnit report per run into a checkout that
# this step created moments earlier, so these bounds are far above anything a
# healthy run produces and exist only to cap a hostile or corrupted tree.
MAX_REPORT_BYTES = 8 * 1024 * 1024
MAX_SCAN_ENTRIES = 512
MAX_CASES_PARSED = 5000
MAX_CASES_RECORDED = 1000
REPORT_PREFIX = "test-run"
REPORT_SUFFIX = ".xml"
# JUnit child tag -> the outcome token published for the testcase, worst first:
# this is also the precedence order, see case_outcome(). The token is singular
# and is deliberately not the plural key the same outcome uses under "totals".
OUTCOMES = (("error", "error"), ("failure", "failed"), ("skipped", "skipped"))
# Outcome token -> its counter under "totals".
TOTALS_KEY = {"passed": "passed", "failed": "failed", "error": "errors",
              "skipped": "skipped"}


class Unavailable(Exception):
    """A refusal, carrying a fixed reason token and only integer fields.

    The token travels on the exception rather than being recovered from its
    message, because an OSError message carries a path and no exception text is
    ever copied into the summary.
    """

    def __init__(self, reason, **fields):
        super().__init__(reason)
        self.reason = reason
        self.fields = fields


def collect_candidates(root_fd):
    """List (dated directory, report) pairs without following any link."""
    budget = MAX_SCAN_ENTRIES
    candidates = []
    with os.scandir(root_fd) as entries:
        for entry in entries:
            budget -= 1
            if budget < 0:
                raise Unavailable("scan-limit")
            if not entry.is_dir(follow_symlinks=False):
                continue
            date_fd = os.open(entry.name, DIR_FLAGS, dir_fd=root_fd)
            try:
                with os.scandir(date_fd) as children:
                    for child in children:
                        budget -= 1
                        if budget < 0:
                            raise Unavailable("scan-limit")
                        if not child.name.startswith(REPORT_PREFIX):
                            continue
                        if not child.name.endswith(REPORT_SUFFIX):
                            continue
                        if not child.is_file(follow_symlinks=False):
                            continue
                        candidates.append((entry.name, child.name))
            finally:
                os.close(date_fd)
    return candidates


def read_report(results_root, date_name, report_name):
    """Read one report, opening every component relative to a directory.

    Both names come from scandir, so neither can contain a separator or a
    relative component, and O_NOFOLLOW on each open means no link anywhere in
    the tree can redirect the read outside the results root.
    """
    root_fd = os.open(results_root, DIR_FLAGS)
    try:
        date_fd = os.open(date_name, DIR_FLAGS, dir_fd=root_fd)
        try:
            # O_NONBLOCK so a fifo that replaced the report between the scan
            # and this open returns instead of parking the step on a read with
            # no writer until the four hour step timeout. It is a no-op for the
            # regular file this is meant to be, and the check below still runs.
            descriptor = os.open(report_name,
                                 os.O_RDONLY | os.O_NOFOLLOW | os.O_NONBLOCK,
                                 dir_fd=date_fd)
        finally:
            os.close(date_fd)
    finally:
        os.close(root_fd)
    with os.fdopen(descriptor, "rb") as report:
        if not stat.S_ISREG(os.fstat(report.fileno()).st_mode):
            raise Unavailable("irregular-report")
        data = report.read(MAX_REPORT_BYTES + 1)
    if len(data) > MAX_REPORT_BYTES:
        raise Unavailable("oversized-report")
    return data


def case_outcome(case):
    """Classify one testcase from the tag names of its direct children.

    Standard JUnit: an <error> outranks a <failure>, which outranks a
    <skipped>, and a testcase carrying none of them passed. Only tag names are
    read - never an attribute or element text, both of which hold free-form
    detail - so an unrecognised child cannot smuggle anything into the summary.
    """
    present = set()
    for child in case:
        if isinstance(child.tag, str):
            present.add(child.tag)
    for tag, outcome in OUTCOMES:
        if tag in present:
            return outcome
    return "passed"


def summarise(data):
    """Tally the report, refusing anything that is not plainly well formed."""
    if data[:3] == b"\xef\xbb\xbf":
        data = data[3:]
    # The doctype check below is a byte scan, so it only holds for an
    # ASCII compatible encoding; expat would otherwise honour a UTF-16 or
    # UTF-32 declaration and parse right past it. The runner writes UTF-8, so
    # anything whose first bytes are not a plain ASCII "<" is refused here
    # rather than handed to a parser this check cannot cover.
    if not data.startswith(b"<") or b"\x00" in data[:4]:
        raise Unavailable("unsupported-encoding")
    # ElementTree expands internally declared entities, which is an
    # amplification vector on input this step does not control. The runner's
    # output has no doctype, so a document carrying one is refused outright
    # rather than parsed. XML keywords are case sensitive, so an exact match is
    # the whole test, and a conforming serialiser escapes "<" everywhere it is
    # not markup, so this cannot fire on captured output that quotes a doctype.
    if b"<!DOCTYPE" in data or b"<!ENTITY" in data:
        raise Unavailable("doctype-rejected")
    try:
        root = ET.fromstring(data)
    except (ET.ParseError, ValueError):
        raise Unavailable("malformed-report")
    if root.tag not in ("testsuite", "testsuites"):
        raise Unavailable("unexpected-root")
    # Every <testsuite> at any depth, not only the root's own children: a suite
    # nested one level deeper would otherwise be dropped silently, and dropping
    # a suite loses its failures while still reporting success. Each suite then
    # tallies only its direct <testcase> children, so a nested suite's cases are
    # counted once, under the suite they belong to.
    suites = list(root.iter("testsuite"))
    if not suites:
        raise Unavailable("no-testsuites")

    totals = {"tests": 0, "passed": 0, "failed": 0, "errors": 0, "skipped": 0}
    cases = []
    for index, suite in enumerate(suites, start=1):
        suite_id = "suite-%04d" % index
        for case in suite.iterfind("testcase"):
            totals["tests"] += 1
            if totals["tests"] > MAX_CASES_PARSED:
                raise Unavailable("report-too-large")
            outcome = case_outcome(case)
            totals[TOTALS_KEY[outcome]] += 1
            if len(cases) < MAX_CASES_RECORDED:
                cases.append({"id": "case-%04d" % totals["tests"],
                              "suite": suite_id,
                              "outcome": outcome})
    return {
        "schema": SCHEMA,
        "status": "summarized",
        "suites": len(suites),
        "totals": totals,
        "cases": cases,
        "cases_dropped": totals["tests"] - len(cases),
    }


def build(results_root):
    """Produce the summary for the one report the runner should have left."""
    try:
        root_fd = os.open(results_root, DIR_FLAGS)
    except FileNotFoundError:
        raise Unavailable("no-results-directory")
    try:
        candidates = collect_candidates(root_fd)
    finally:
        os.close(root_fd)
    if not candidates:
        raise Unavailable("no-report")
    if len(candidates) > 1:
        # Guessing which of several reports describes this run would publish
        # results that may belong to another one.
        raise Unavailable("ambiguous-report", reports_seen=len(candidates))
    return summarise(read_report(results_root, *candidates[0]))


def write_summary(summary_path, summary):
    """Write the summary, refusing to follow a link at the destination.

    A write that fails part way - the artifact directory filling up behind the
    tee'd runner log is the realistic way - leaves bytes already flushed on
    disk. Half a JSON document published as the summary is worse than none,
    and it would also satisfy the caller's "is the artifact there" fallback
    test, so the remains are removed before the failure is reported.
    """
    descriptor = os.open(summary_path,
                         os.O_WRONLY | os.O_CREAT | os.O_EXCL | os.O_NOFOLLOW, 0o644)
    try:
        with os.fdopen(descriptor, "w") as artifact:
            json.dump(summary, artifact, sort_keys=True)
            artifact.write("\n")
    except Exception:
        try:
            os.unlink(summary_path)
        except OSError:
            pass
        raise


def main(argv):
    """Summarise, then report the outcome in integers and fixed tokens only."""
    results_root, summary_path = argv[1], argv[2]
    try:
        summary = build(results_root)
    except Unavailable as refusal:
        summary = dict(refusal.fields, schema=SCHEMA, status="unavailable",
                       reason=refusal.reason)
    except OSError as error:
        summary = {"schema": SCHEMA, "status": "unavailable", "reason": "io-error",
                   "errno": error.errno}
    except Exception:  # pylint: disable=broad-except
        summary = {"schema": SCHEMA, "status": "unavailable", "reason": "internal-error"}

    try:
        write_summary(summary_path, summary)
    except Exception:  # pylint: disable=broad-except
        # The caller writes its own fallback when the artifact is absent, so
        # this path stays silent about why - the reason could name a path.
        print("WARNING: could not write the structured result summary")
        return 0

    if summary["status"] == "summarized":
        totals = summary["totals"]
        print("Structured results: %d tests, %d passed, %d failed, %d errors, %d skipped"
              % (totals["tests"], totals["passed"], totals["failed"],
                 totals["errors"], totals["skipped"]))
    else:
        # WARNING, because an upstream change to the runner's output layout
        # would otherwise degrade every build to this line unnoticed.
        print("WARNING: structured results unavailable (reason=%s)" % summary["reason"])
    return 0


if __name__ == "__main__":
    sys.exit(main(sys.argv))
PYTHON_HELPER
}

echo "Running rosa-hcp-e2e tests (name_prefix=${NAME_PREFIX})..."
RESULTS_ROOT="${PWD}/test-results"
# The step must exit with the runner's own status, but under pipefail a
# pipeline reports the rightmost non-zero status - tee's, whenever tee is the
# one that failed. A tee that cannot write the log would therefore fail an
# otherwise passing run, and, worse, replace a real failure's status with its
# own. Take the whole PIPESTATUS array in a single assignment: any command run
# in between replaces it, so the two statuses cannot be read one at a time. The
# default stands when the pipeline succeeds and the || branch is not taken.
PIPE_STATUS=(0 0)
"${PYTHON}" run-test-suite.py ${TEST_SUITE} --ai-agent "${EXTRA_VARS[@]}" 2>&1 | tee "${ARTIFACT_DIR}/rosa-hcp-e2e-test.log" || PIPE_STATUS=("${PIPESTATUS[@]}")
RUN_STATUS=${PIPE_STATUS[0]}
if [[ "${PIPE_STATUS[1]:-0}" -ne 0 ]]; then
  # Not fatal - the runner's own status still decides the step - but the log
  # is the artifact everything else refers to, so say that it is unreliable.
  echo "WARNING: tee exited ${PIPE_STATUS[1]}; ${ARTIFACT_DIR}/rosa-hcp-e2e-test.log may be incomplete" >&2
fi

# Best effort, and deliberately after RUN_STATUS has been captured: the step
# still exits with the runner's own status below, whatever the export does.
# The summariser is the only writer of the artifact. It creates its destination
# with O_CREAT|O_EXCL|O_NOFOLLOW and records every refusal it can reach as a
# reason token inside the file itself, so a shell-side placeholder would add
# nothing except a second, weaker path to the same destination: a redirection
# cannot be made to refuse a fifo or a device that appears underneath it, and
# that path would be the one undoing the summariser's guarantee. There is
# therefore no fallback, and a run whose summariser could not run at all simply
# publishes no summary, which the step's documentation states.
export_structured_results "${RESULTS_ROOT}" "${ARTIFACT_DIR}/${SUMMARY_NAME}" || true

if [[ "${RUN_STATUS}" -eq 0 ]]; then
  echo "Tests complete. Results at ${ARTIFACT_DIR}/rosa-hcp-e2e-test.log"
else
  echo "Tests failed with status ${RUN_STATUS}. Results at ${ARTIFACT_DIR}/rosa-hcp-e2e-test.log" >&2
fi

exit "${RUN_STATUS}"
