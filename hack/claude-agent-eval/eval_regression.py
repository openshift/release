#!/usr/bin/env python3
"""Apply harness thresholds to the run directory already verified by the runner."""

import argparse
import importlib
from pathlib import Path
import sys

import yaml


def main():
    """Use the cloned harness's scoring rules without repeating its path lookup."""
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--harness", type=Path, required=True)
    parser.add_argument("--config", type=Path, required=True)
    parser.add_argument("--run-dir", type=Path, required=True)
    args = parser.parse_args()

    # Keep harness imports in this bounded child process. Import from the same
    # scripts directory as the score.py CLI, including its agent_eval package.
    sys.path.insert(0, str(args.harness / "skills/eval-run/scripts"))
    score = importlib.import_module("score")
    config = score.EvalConfig.from_yaml(args.config)
    summary_path = args.run_dir / "summary.yaml"
    print(f"SUMMARY: {summary_path}", flush=True)
    with summary_path.open(encoding="utf-8") as stream:
        summary = yaml.safe_load(stream)
    if not isinstance(summary, dict) or not isinstance(summary.get("judges"), dict):
        raise ValueError("harness did not produce a judges summary")
    for judge in config.thresholds:
        if judge not in summary["judges"]:
            raise ValueError(f"missing thresholded judge in summary: {judge}")
    regressions = score.detect_regressions(summary["judges"], config.thresholds)
    print(f"REGRESSIONS: {len(regressions)}")
    for regression in regressions:
        print(f"  [{regression.judge_name}] {regression.metric}: "
              f"{regression.baseline_value} -> {regression.current_value}")
    return 1 if regressions else 0


if __name__ == "__main__":
    sys.exit(main())
