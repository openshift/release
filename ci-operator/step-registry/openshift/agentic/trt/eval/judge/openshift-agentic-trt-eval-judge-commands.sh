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

# Failed solves have no published head to collect. Record those failures in
# JUnit, then let the existing CLI judge successful solves together as before.
python3 - "${EVAL_CONFIG}" "${SHARED_DIR}" "${ARTIFACT_DIR}" <<'JUDGE_PY'
from pathlib import Path
import shutil
import subprocess
import sys
import tempfile
import xml.etree.ElementTree as ET

config, shared, artifacts = sys.argv[1:]
shared, artifacts = Path(shared), Path(artifacts)
cases = (shared / "eval-cases").read_text().splitlines()
cases = [case for case in cases if case.strip()]
if not cases:
    raise SystemExit("ERROR: no cases to judge")
passed, failures = [], 0
suite = ET.Element("testsuite", name="jira-solver-eval-solves")
for case in cases:
    try:
        rc = int((shared / f"{case}.solve-exit-code").read_text().strip())
    except (OSError, ValueError):
        rc = 1
    testcase = ET.SubElement(suite, "testcase", name=f"{case} solve",
                             classname=f"jira-solver-eval.{case}")
    if rc:
        failures += 1
        reason = f"solver exit {rc}; see solve-{case}.log"
        ET.SubElement(testcase, "failure", message=reason).text = reason
        print(f"[FAIL] {case}: {reason}", flush=True)
    else:
        passed.append(case)
suite.set("tests", str(len(cases)))
suite.set("failures", str(failures))
root = ET.Element("testsuites")
root.append(suite)
ET.ElementTree(root).write(artifacts / "junit_solve.xml", encoding="utf-8", xml_declaration=True)

judge_rc = 0
if passed:
    # Do not change the real case list: cleanup still needs every case.
    with tempfile.TemporaryDirectory(prefix="eval-judge-") as directory:
        subset = Path(directory)
        (subset / "eval-cases").write_text("\n".join(passed) + "\n")
        for case in passed:
            for path in shared.glob(f"{case}.*"):
                if path.is_file():
                    shutil.copyfile(path, subset / path.name)
        metrics = shared / "eval-solve-run-result.json"
        if metrics.is_file():
            shutil.copyfile(metrics, subset / metrics.name)
        judge_rc = subprocess.run(
            ["prow-agent-eval", "judge", f"--config={config}", f"--shared-dir={subset}",
             f"--artifact-dir={artifacts}", "--mode=solve"], check=False).returncode
raise SystemExit(1 if failures or judge_rc else 0)
JUDGE_PY

echo "=== TRT Eval Judge Complete ==="
