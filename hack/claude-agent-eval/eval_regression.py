#!/usr/bin/env python3
"""Apply the runner's preflight thresholds to the run directory it already verified."""

import argparse
import importlib
import json
from pathlib import Path
import sys

import yaml

try:
    from .eval_plan import EvalError, validate_thresholds
except ImportError:
    from eval_plan import EvalError, validate_thresholds


def parse_thresholds(text):
    """Decode the thresholds the parent resolved before the orchestrator ran."""
    try:
        document = json.loads(text)
    except ValueError as error:
        raise EvalError(f"--thresholds must be JSON: {error}") from error
    return validate_thresholds(document)


def main():
    """Use the cloned harness's scoring rules without re-reading the eval YAML."""
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--harness", type=Path, required=True)
    parser.add_argument("--run-dir", type=Path, required=True)
    parser.add_argument("--thresholds", required=True,
                        help="JSON mapping of judge thresholds resolved at preflight")
    args = parser.parse_args()
    # The orchestrator runs with write access to the checkout before scoring,
    # so re-resolving the config here would let the skill under test lower its
    # own thresholds. Only the parent's preflight resolution decides pass/fail.
    thresholds = parse_thresholds(args.thresholds)

    # Keep harness imports in this bounded child process. Import from the same
    # scripts directory as the score.py CLI, including its agent_eval package.
    scripts = (args.harness.resolve() / "skills/eval-run/scripts").resolve()
    sys.path.insert(0, str(scripts))
    loaded_score = sys.modules.get("score")
    loaded_path = getattr(loaded_score, "__file__", None)
    if loaded_score is not None and (
            not loaded_path or not Path(loaded_path).resolve().is_relative_to(scripts)):
        del sys.modules["score"]
    score = importlib.import_module("score")
    if not Path(score.__file__).resolve().is_relative_to(scripts):
        raise ValueError(f"score module imported from outside the supplied harness: {score.__file__}")
    summary_path = args.run_dir / "summary.yaml"
    print(f"SUMMARY: {summary_path}", flush=True)
    with summary_path.open(encoding="utf-8") as stream:
        summary = yaml.safe_load(stream)
    if not isinstance(summary, dict) or not isinstance(summary.get("judges"), dict):
        raise ValueError("harness did not produce a judges summary")
    for judge in thresholds:
        if judge not in summary["judges"]:
            raise ValueError(f"missing thresholded judge in summary: {judge}")
    regressions = score.detect_regressions(summary["judges"], thresholds)
    print(f"REGRESSIONS: {len(regressions)}")
    for regression in regressions:
        print(f"  [{regression.judge_name}] {regression.metric}: "
              f"{regression.baseline_value} -> {regression.current_value}")
    return 1 if regressions else 0


if __name__ == "__main__":
    sys.exit(main())
