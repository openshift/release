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

import math
import os
import sys
import xml.etree.ElementTree as ET
from pathlib import Path

# Global counter for XML parse failures
_parse_failures = 0


def parse_junit(path):
    """Parse a single JUnit XML file and return per-suite tallies.

    Handles both <testsuites> (wrapper) and bare <testsuite> roots.
    Returns a list of dicts with keys: name, tests, passed, failed,
    skipped, errored.
    """
    suites = []
    try:
        tree = ET.parse(path)
    except ET.ParseError as exc:
        global _parse_failures
        _parse_failures += 1
        print(f"WARNING: skipping {path} — XML parse error: {exc}", file=sys.stderr)
        return suites

    root = tree.getroot()

    # Collect <testsuite> elements regardless of root tag
    if root.tag == "testsuite":
        suite_elements = [root]
    elif root.tag == "testsuites":
        suite_elements = root.findall("testsuite")
    else:
        print(f"WARNING: skipping {path} — unexpected root <{root.tag}>", file=sys.stderr)
        return suites

    for ts in suite_elements:
        tests = int(ts.get("tests", 0))
        failures = int(ts.get("failures", 0))
        errors = int(ts.get("errors", 0))
        skipped_attr = int(ts.get("skipped", ts.get("skip", 0)))

        # Some generators omit the skipped attribute but include
        # <skipped/> child elements inside <testcase>.
        if skipped_attr == 0:
            skipped_attr = sum(
                1 for tc in ts.findall("testcase")
                if tc.find("skipped") is not None
            )

        passed = max(0, tests - failures - errors - skipped_attr)

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


def write_gate_junit(artifact_dir, total, passed, failed, skipped, errored,
                     skip_ratio, threshold, breach):
    """Write a single-testcase JUnit XML summarising the gate result."""
    out = Path(artifact_dir) / "skip-ratio-gate.xml"

    suite_status = "failure" if breach else "success"
    tc_name = f"skip-ratio-gate (ratio={skip_ratio:.4f}, threshold={threshold:.4f})"

    lines = [
        '<?xml version="1.0" encoding="UTF-8"?>',
        f'<testsuite name="skip-ratio-gate" tests="1" failures="{1 if breach else 0}">',
        f'  <testcase name="{tc_name}" classname="interop.opp.skip-ratio-gate">',
    ]
    if breach:
        lines.append(
            f'    <failure message="Skip ratio {skip_ratio:.4f} exceeds threshold {threshold:.4f}">'
            f'Total={total} Passed={passed} Failed={failed} Skipped={skipped} Errored={errored}'
            f'</failure>'
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
    shared_junit = os.path.join(shared_dir, "junit") if shared_dir else ""
    junit_dir = os.environ.get("JUNIT_DIR", "") or (shared_junit if os.path.isdir(shared_junit) else "") or os.environ.get("ARTIFACT_DIR", "")
    fail_on_breach = os.environ.get("FAIL_ON_BREACH", "true").lower() != "false"
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
        if fail_on_breach:
            print(f"ERROR: no *.xml files found in {junit_dir}", file=sys.stderr)
            write_gate_junit(artifact_dir, 0, 0, 0, 0, 0, 0.0, threshold, True)
            sys.exit(1)
        else:
            print(f"WARNING: no *.xml files found in {junit_dir} "
                  f"(FAIL_ON_BREACH=false, not failing)")
            write_gate_junit(artifact_dir, 0, 0, 0, 0, 0, 0.0, threshold, False)
            sys.exit(0)

    all_suites = []
    for xf in xml_files:
        all_suites.extend(parse_junit(xf))

    if _parse_failures:
        print(f"ERROR: {_parse_failures} JUnit XML file(s) failed to parse",
              file=sys.stderr)
        write_gate_junit(artifact_dir, 0, 0, 0, 0, 0, 0.0, threshold, True)
        sys.exit(1)

    if not all_suites:
        print("ERROR: XML files found but no <testsuite> elements parsed",
              file=sys.stderr)
        # Unparseable reports are suspicious — record a failing gate and exit non-zero
        write_gate_junit(artifact_dir, 0, 0, 0, 0, 0, 0.0, threshold, True)
        sys.exit(1)

    # Aggregate totals
    total_passed = sum(s["passed"] for s in all_suites)
    total_failed = sum(s["failed"] for s in all_suites)
    total_skipped = sum(s["skipped"] for s in all_suites)
    total_errored = sum(s["errored"] for s in all_suites)
    grand_total = total_passed + total_failed + total_skipped + total_errored

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

    write_gate_junit(artifact_dir, grand_total, total_passed, total_failed,
                     total_skipped, total_errored, skip_ratio, threshold, breach)

    if breach and fail_on_breach:
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
