#!/bin/bash
set -euo pipefail; shopt -s inherit_errexit

# Wrapper: exec into a pure-stdlib Python script that scans JUnit XML
# files, computes the overall skip ratio, and optionally fails the step
# when the ratio exceeds the configured threshold.
exec python3 - <<'PYTHON_SCRIPT'
"""Skip-ratio health gate for OPP interop testing.

Scans JUnit XML files in JUNIT_DIR (or ARTIFACT_DIR), tallies
passed / failed / skipped / errored counts, computes the skip ratio,
prints a summary table, writes a gate JUnit XML, and exits non-zero
when the ratio exceeds SKIP_RATIO_THRESHOLD (unless FAIL_ON_BREACH
is "false").
"""

import hashlib
import math
import os
import sys
import xml.etree.ElementTree as ET
from pathlib import Path
from xml.sax.saxutils import escape

# Global counter for XML parse failures
_parse_failures = 0


def parse_junit(path):
    """Parse a single JUnit XML file and return per-suite tallies.

    Handles both <testsuites> (wrapper) and bare <testsuite> roots.
    Returns a list of dicts with keys: name, tests, passed, failed,
    skipped, errored.

    Robust parsing (INTEROP-9527):
    - Empty files are reported as parse failures
    - Testcase child elements are counted and used to cross-validate
      the ``tests`` attribute; when the attribute is absent or zero
      but testcases exist, the count is derived from the children.
      Suites that declare more tests than they contain are rejected
      as incomplete evidence
    - Failure/skipped child elements are counted directly for accuracy
    """
    global _parse_failures
    suites = []

    # Guard: empty or effectively-empty files
    try:
        if path.stat().st_size == 0:
            _parse_failures += 1
            print(f"WARNING: skipping {path} — file is empty", file=sys.stderr)
            return suites
    except OSError:
        pass

    try:
        tree = ET.parse(path)
    except (ET.ParseError, OSError) as exc:
        _parse_failures += 1
        print(f"WARNING: skipping {path} — XML parse error: {exc}", file=sys.stderr)
        return suites

    root = tree.getroot()

    # Collect <testsuite> elements regardless of root tag
    if root.tag == "testsuite":
        suite_elements = list(root.iter("testsuite"))
    elif root.tag == "testsuites":
        suite_elements = list(root.iter("testsuite"))
    else:
        _parse_failures += 1
        print(f"WARNING: skipping {path} — unexpected root <{root.tag}>", file=sys.stderr)
        return suites

    for ts in suite_elements:
        testcases = ts.findall("testcase")
        tc_count = len(testcases)

        # Cross-validate: derive a missing count from testcase children,
        # but reject suites whose declared count includes missing cases.
        try:
            tests_attr = int(ts.get("tests", 0))
            failures = int(ts.get("failures", 0))
            errors = int(ts.get("errors", 0))
            skipped_attr = int(ts.get("skipped", ts.get("skip", 0)))
            if any(value < 0 for value in (tests_attr, failures, errors, skipped_attr)):
                raise ValueError("negative JUnit count")
        except (ValueError, TypeError) as exc:
            _parse_failures += 1
            print(f"WARNING: invalid counts in {path}: {exc}", file=sys.stderr)
            continue
        # Parent suite counts aggregate descendants. Validate the aggregate,
        # but count each direct testcase only in its owning suite.
        descendants = list(ts.iter("testcase"))
        if tests_attr > len(descendants):
            _parse_failures += 1
            suite_name = ts.get("name", path.name)
            print(
                f"WARNING: skipping suite {suite_name!r} in {path} — "
                f"declares tests={tests_attr} but contains only "
                f"{len(descendants)} <testcase> descendant element(s)",
                file=sys.stderr,
            )
            continue
        if ts.findall("testsuite"):
            child_outcomes = (
                sum(tc.find("failure") is not None for tc in descendants),
                sum(tc.find("error") is not None for tc in descendants),
                sum(tc.find("skipped") is not None for tc in descendants),
            )
            if (failures > child_outcomes[0] or errors > child_outcomes[1]
                    or skipped_attr > child_outcomes[2]):
                _parse_failures += 1
                print(f"WARNING: parent outcome counts lack testcase evidence in {path}", file=sys.stderr)
                continue
            failures = errors = skipped_attr = 0
        tests = tc_count
        # Some generators omit the skipped attribute but include
        # <skipped/> child elements inside <testcase>.
        skipped_from_children = sum(
            1 for tc in testcases if tc.find("skipped") is not None
        )
        skipped_attr = max(skipped_attr, skipped_from_children)

        # Cross-validate failure count from children too
        failures_from_children = sum(
            1 for tc in testcases if tc.find("failure") is not None
        )
        failures = max(failures, failures_from_children)

        errors_from_children = sum(
            1 for tc in testcases if tc.find("error") is not None
        )
        errors = max(errors, errors_from_children)
        if failures + errors + skipped_attr > tests:
            _parse_failures += 1
            print(f"WARNING: contradictory outcome counts in {path}", file=sys.stderr)
            continue

        if not testcases:
            continue

        passed = tests - failures - errors - skipped_attr

        suites.append({
            "name": ts.get("name", path.name),
            "file": str(path),
            "tests": tests,
            "passed": passed,
            "failed": failures,
            "skipped": skipped_attr,
            "errored": errors,
        })

    return suites


def write_evidence_incomplete_junit(artifact_dir, threshold, reason):
    """Write evidence-incomplete gate JUnit when no valid measurement is possible."""
    out = Path(artifact_dir) / "skip-ratio-gate.xml"
    lines = [
        '<?xml version="1.0" encoding="UTF-8"?>',
        f'<testsuite name="lp-interop--OPP--skip-gate" tests="1" failures="0" skipped="1">',
        f'  <testcase name="skip-ratio-gate (evidence-incomplete)" classname="interop.opp.skip-ratio-gate">',
        f'    <skipped message="EVIDENCE-INCOMPLETE">{escape(reason)}. '
        f'Skip-ratio gate requires valid test results to measure. '
        f'Threshold={threshold:.4f}</skipped>',
        '  </testcase>',
        '</testsuite>',
    ]
    out.write_text("\n".join(lines) + "\n", encoding="utf-8")
    print(f"Wrote evidence-incomplete gate JUnit to {out}")


def write_gate_junit(artifact_dir, total, passed, failed, skipped, errored,
                     skip_ratio, threshold, breach, advisory_breach=False):
    """Write a single-testcase JUnit XML summarising the gate result."""
    out = Path(artifact_dir) / "skip-ratio-gate.xml"

    tc_name = f"skip-ratio-gate (ratio={skip_ratio:.4f}, threshold={threshold:.4f})"

    fail_count = 1 if breach else 0
    lines = [
        '<?xml version="1.0" encoding="UTF-8"?>',
        f'<testsuite name="lp-interop--OPP--skip-gate" tests="1" failures="{fail_count}">',
        f'  <testcase name="{tc_name}" classname="interop.opp.skip-ratio-gate">',
    ]
    if breach:
        lines.append(
            f'    <failure message="Skip ratio {skip_ratio:.4f} exceeds threshold {threshold:.4f}">'
            f'Total={total} Passed={passed} Failed={failed} Skipped={skipped} Errored={errored}'
            f'</failure>'
        )
    elif advisory_breach:
        lines.append(
            f'    <system-out>ADVISORY: skip ratio {skip_ratio:.4f} exceeds threshold '
            f'{threshold:.4f} (FAIL_ON_BREACH=false, not failing). '
            f'Total={total} Passed={passed} Failed={failed} Skipped={skipped} '
            f'Errored={errored}</system-out>'
        )
    lines += [
        "  </testcase>",
        "</testsuite>",
    ]

    out.write_text("\n".join(lines) + "\n", encoding="utf-8")
    print(f"Wrote gate JUnit XML to {out}")


def main():
    threshold = float(os.environ.get("SKIP_RATIO_THRESHOLD", "0.10"))
    if not math.isfinite(threshold) or threshold < 0 or threshold > 1:
        print(f"ERROR: SKIP_RATIO_THRESHOLD must be a finite number in [0, 1], got {threshold!r}",
              file=sys.stderr)
        sys.exit(1)
    shared_dir = os.environ.get("SHARED_DIR", "")
    junit_dir = (
        os.environ.get("JUNIT_DIR", "")
        or (shared_dir if shared_dir and any(Path(shared_dir).rglob("*.xml")) else "")
        or os.environ.get("ARTIFACT_DIR", "")
    )
    # Default matches the ref.yaml default ("false" = advisory-only mode).
    # ci-operator sets the env var from the YAML default, but aligning the
    # Python fallback avoids surprises when running the script standalone.
    fail_on_breach = os.environ.get("FAIL_ON_BREACH", "false").lower() != "false"
    artifact_dir = os.environ.get("ARTIFACT_DIR", junit_dir)

    if not junit_dir:
        print("ERROR: neither JUNIT_DIR nor ARTIFACT_DIR is set", file=sys.stderr)
        sys.exit(1)

    junit_path = Path(junit_dir)
    if not junit_path.is_dir():
        print(f"ERROR: JUNIT_DIR {junit_dir} does not exist or is not a directory",
              file=sys.stderr)
        sys.exit(1)

    # Recursively find all XML files, excluding our own gate output
    # (guards against JUNIT_DIR == ARTIFACT_DIR on re-runs)
    gate_junit = (Path(artifact_dir) / "skip-ratio-gate.xml").resolve()
    xml_files = sorted(
        p for p in junit_path.rglob("*.xml")
        if p.resolve() != gate_junit
    )
    if not xml_files:
        reason = f"no JUnit XML files in {junit_dir}"
        print(f"EVIDENCE-INCOMPLETE: {reason}", file=sys.stderr)
        write_evidence_incomplete_junit(artifact_dir, threshold, reason)
        sys.exit(0)

    all_suites = []
    seen_artifacts = set()
    for xf in xml_files:
        try:
            fingerprint = hashlib.sha256(xf.read_bytes()).digest()
        except OSError:
            # parse_junit owns the incomplete-evidence reporting.
            all_suites.extend(parse_junit(xf))
            continue
        if fingerprint in seen_artifacts:
            print(f"WARNING: duplicate identical JUnit artifact ignored: {xf}", file=sys.stderr)
            continue
        seen_artifacts.add(fingerprint)
        all_suites.extend(parse_junit(xf))

    if _parse_failures:
        reason = f"{_parse_failures} JUnit parse/validation failure(s)"
        print(f"EVIDENCE-INCOMPLETE: {reason}", file=sys.stderr)
        write_evidence_incomplete_junit(artifact_dir, threshold, reason)
        sys.exit(0)

    if not all_suites:
        reason = "XML files found but no <testsuite> elements"
        print(f"EVIDENCE-INCOMPLETE: {reason}", file=sys.stderr)
        write_evidence_incomplete_junit(artifact_dir, threshold, reason)
        sys.exit(0)

    # Aggregate totals
    total_passed = sum(s["passed"] for s in all_suites)
    total_failed = sum(s["failed"] for s in all_suites)
    total_skipped = sum(s["skipped"] for s in all_suites)
    total_errored = sum(s["errored"] for s in all_suites)
    grand_total = total_passed + total_failed + total_skipped + total_errored

    # Evidence-incomplete guard: suites were parsed but reported zero
    # tests, so there is no meaningful data to compute a skip ratio.
    if grand_total == 0:
        reason = "test suites report 0 total tests"
        print(f"EVIDENCE-INCOMPLETE: {reason}", file=sys.stderr)
        write_evidence_incomplete_junit(artifact_dir, threshold, reason)
        sys.exit(0)

    skip_ratio = total_skipped / grand_total if grand_total > 0 else 0.0
    breach = skip_ratio > threshold

    # Print summary table
    hdr = f"{'Suite':<50} {'Tests':>6} {'Pass':>6} {'Fail':>6} {'Skip':>6} {'Err':>6} {'SkipR':>7}"
    sep = "-" * len(hdr)
    print(sep)
    print(hdr)
    print(sep)
    for s in all_suites:
        st = s["passed"] + s["failed"] + s["skipped"] + s["errored"]
        sr = s["skipped"] / st if st > 0 else 0.0
        name = s["name"][:50]
        print(f"{name:<50} {st:>6} {s['passed']:>6} {s['failed']:>6} {s['skipped']:>6} {s['errored']:>6} {sr:>7.4f}")
    print(sep)
    print(f"{'TOTAL':<50} {grand_total:>6} {total_passed:>6} {total_failed:>6} {total_skipped:>6} {total_errored:>6} {skip_ratio:>7.4f}")
    print(sep)
    print(f"Threshold: {threshold:.4f}   Skip ratio: {skip_ratio:.4f}   "
          f"{'BREACH' if breach else 'OK'}")
    print(f"FAIL_ON_BREACH: {fail_on_breach}")

    is_failing_breach = breach and fail_on_breach
    is_advisory_breach = breach and not fail_on_breach

    write_gate_junit(artifact_dir, grand_total, total_passed, total_failed,
                     total_skipped, total_errored, skip_ratio, threshold,
                     is_failing_breach, is_advisory_breach)

    if is_failing_breach:
        print(f"FAIL: skip ratio {skip_ratio:.4f} exceeds threshold {threshold:.4f}",
              file=sys.stderr)
        sys.exit(1)
    elif breach:
        print(f"ADVISORY: skip ratio {skip_ratio:.4f} exceeds threshold {threshold:.4f} "
              f"(FAIL_ON_BREACH=false, not failing)")
    else:
        print("PASS: skip ratio within threshold")


if __name__ == "__main__":
    main()
PYTHON_SCRIPT
