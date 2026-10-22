#!/bin/bash

set -o nounset
set -o errexit
set -o pipefail

echo "=== TRT Eval Judge ==="

# Disable tracing while loading secret
set +x
GITHUB_TOKEN=$(cat "${SHARED_DIR}/gh-upstream-token")
export GITHUB_TOKEN

EVAL_CONFIG="${EVAL_CONFIG:-/opt/ai-helpers/evals/trt-agentic-solve/solve-eval.yaml}"

# Isolate cases using the CLI's supported --case option. A failed solve has no
# published head to collect; report it directly instead of letting collection
# abort the entire evaluation before the remaining cases can be judged.
python3 - "${EVAL_CONFIG}" "${SHARED_DIR}" "${ARTIFACT_DIR}" <<'JUDGE_PY'
import html
import json
from pathlib import Path
import subprocess
import sys
import xml.etree.ElementTree as ET

config, shared, artifacts = sys.argv[1:]
shared, artifacts = Path(shared), Path(artifacts)
cases = (shared / "eval-cases").read_text().splitlines()
cases = [case for case in cases if case.strip()]
if not cases:
    raise SystemExit("ERROR: no cases to judge")
outcomes = []
suite = ET.Element("testsuite", name="jira-solver-eval-outcomes")
for case in cases:
    outcome = {"case": case, "status": "failed", "phase": "solve", "exit_code": 1}
    try:
        status = json.loads((shared / f"{case}.solve-status.json").read_text())
        if not isinstance(status, dict):
            raise ValueError("invalid solve status")
        outcome.update(phase=status.get("phase", "solve"), exit_code=status.get("exit_code", 1),
                       reason=status.get("reason", "solve did not complete"))
        if status.get("status") == "passed" and status.get("exit_code") == 0:
            output = artifacts / "cases" / case
            output.mkdir(parents=True, exist_ok=True)
            print(f"Judging {case}", flush=True)
            with (output / "judge.log").open("w") as log:
                process = subprocess.run(
                    ["prow-agent-eval", "judge", f"--config={config}", f"--shared-dir={shared}",
                     f"--artifact-dir={output}", "--mode=solve", f"--case={case}"],
                    stdout=log, stderr=subprocess.STDOUT, check=False)
            reports = list(output.glob("junit*.xml"))
            passed = process.returncode == 0 and bool(reports)
            outcome.update(status="passed" if passed else "failed", phase="judge",
                           exit_code=process.returncode if process.returncode else (0 if reports else 1),
                           reason="judges passed" if passed else "judge failed; see per-case judge.log",
                           judge_log=f"cases/{case}/judge.log")
            if (output / "eval-summary.html").is_file():
                outcome["report"] = f"cases/{case}/eval-summary.html"
            print("\n".join((output / "judge.log").read_text(errors="replace").splitlines()[-40:]), flush=True)
    except (OSError, ValueError) as error:
        outcome.update(status="failed", exit_code=1, reason=str(error))
    outcomes.append(outcome)
    testcase = ET.SubElement(suite, "testcase", name=f"{case} {outcome['phase']}",
                             classname=f"jira-solver-eval.{case}")
    if outcome["status"] != "passed":
        ET.SubElement(testcase, "failure", message=outcome["reason"]).text = outcome["reason"]
    print(f"[{outcome['status'].upper()}] {case}: {outcome['reason']}", flush=True)

failures = sum(outcome["status"] != "passed" for outcome in outcomes)
suite.set("tests", str(len(outcomes)))
suite.set("failures", str(failures))
suite.set("errors", "0")
root = ET.Element("testsuites")
root.append(suite)
ET.ElementTree(root).write(artifacts / "junit_solve_outcomes.xml", encoding="utf-8", xml_declaration=True)
(artifacts / "eval-case-results.json").write_text(json.dumps(outcomes, indent=2) + "\n")
# Each case retains its full CLI-generated JUnit/YAML/HTML reports. The root
# index includes failed solves as failures, not missing-head collection errors.
lines = ["<!doctype html><html><head><meta charset='utf-8'><title>Solver evaluation</title></head><body>",
         f"<h1>Solver evaluation</h1><p>{len(outcomes)} cases; {failures} failures.</p><ul>"]
for outcome in outcomes:
    text = html.escape(f"{outcome['case']}: {outcome['status']} — {outcome['reason']}")
    links = []
    for key, label in (("report", "Judge report"), ("judge_log", "Judge log")):
        if key in outcome:
            links.append(f'<a href="{html.escape(outcome[key], quote=True)}">{label}</a>')
    lines.append(f"<li>{text} {' | '.join(links)}</li>")
lines.append("</ul></body></html>")
(artifacts / "eval-summary.html").write_text("\n".join(lines) + "\n")
raise SystemExit(1 if failures else 0)
JUDGE_PY

echo "=== TRT Eval Judge Complete ==="
