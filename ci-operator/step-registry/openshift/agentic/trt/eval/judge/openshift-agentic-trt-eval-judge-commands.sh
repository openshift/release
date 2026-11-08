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
export AGENT_EVAL_RUNS_DIR="${ARTIFACT_DIR}/eval/runs"
EVAL_NAME=$(python3 - "${EVAL_CONFIG}" <<'PY'
import sys

from agent_eval.config import EvalConfig

print(EvalConfig.from_yaml(sys.argv[1]).eval_name())
PY
)
RUN_DIR="${AGENT_EVAL_RUNS_DIR}/${EVAL_NAME}/${EVAL_NAME}"
mkdir -p "${RUN_DIR}"
rm -f "${RUN_DIR}/run_result.json"
if [[ -f "${SHARED_DIR}/eval-solve-run-result.json" ]]; then
    cp "${SHARED_DIR}/eval-solve-run-result.json" "${RUN_DIR}/run_result.json"
fi

set +o errexit
prow-agent-eval judge \
    --config="${EVAL_CONFIG}" \
    --shared-dir="${SHARED_DIR}" \
    --artifact-dir="${ARTIFACT_DIR}" \
    --mode=solve
JUDGE_STATUS=$?
set -o errexit

# Verify after judging so cost problems do not suppress quality reports. Zero
# is a valid observed cost; missing, non-finite, negative, or misassigned cost
# is an explicit eval verification failure.
set +o errexit
python3 - "${RUN_DIR}/run_result.json" "${SHARED_DIR}/eval-cases" <<'PY'
import json
import math
import sys

result_path, cases_path = sys.argv[1:]
with open(cases_path) as handle:
    expected_cases = [line.strip() for line in handle if line.strip()]
with open(result_path) as handle:
    result = json.load(handle)

errors = []
per_case = result.get("per_case")
if not isinstance(per_case, dict) or set(per_case) != set(expected_cases):
    actual = sorted(per_case) if isinstance(per_case, dict) else []
    errors.append(f"case keys differ: expected={sorted(expected_cases)} actual={actual}")
    per_case = per_case if isinstance(per_case, dict) else {}

costs = []
for case_name in expected_cases:
    case = per_case.get(case_name, {})
    cost = case.get("cost_usd")
    if case.get("cost_observed") is not True:
        errors.append(f"{case_name}: observed cost metric is missing")
    if isinstance(cost, bool) or not isinstance(cost, (int, float)):
        errors.append(f"{case_name}: cost is not numeric")
    elif not math.isfinite(cost) or cost < 0:
        errors.append(f"{case_name}: cost is not finite and nonnegative")
    else:
        costs.append(cost)

root_cost = result.get("cost_usd")
if result.get("execution_mode") != "case":
    errors.append("execution_mode is not case")
if result.get("num_cases") != len(expected_cases):
    errors.append("num_cases does not match the eval case list")
if result.get("cost_observed") is not True:
    errors.append("root cost is incomplete")
if isinstance(root_cost, bool) or not isinstance(root_cost, (int, float)):
    errors.append("root cost is not numeric")
elif not math.isfinite(root_cost) or root_cost < 0:
    errors.append("root cost is not finite and nonnegative")
elif len(costs) == len(expected_cases) and not math.isclose(
        root_cost, math.fsum(costs), rel_tol=1e-9, abs_tol=1e-6):
    errors.append("root cost does not equal the per-case sum")

if errors:
    for error in errors:
        print(f"ERROR: eval cost verification: {error}", file=sys.stderr)
    sys.exit(1)
print(f"Verified observed per-case costs for {len(expected_cases)} cases")
PY
COST_STATUS=$?
set -o errexit

echo "=== TRT Eval Judge Complete ==="
if [[ ${JUDGE_STATUS} -ne 0 ]]; then
    exit "${JUDGE_STATUS}"
fi
exit "${COST_STATUS}"
