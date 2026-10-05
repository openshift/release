#!/usr/bin/env python3
"""Apply harness thresholds to the run directory already verified by the runner."""

import argparse
import importlib
from pathlib import Path
import sys

import yaml

try:
    from .eval_config import resolve_config
except ImportError:
    from eval_config import resolve_config


def main():
    """Use the cloned harness's scoring rules without repeating its path lookup."""
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--harness", type=Path, required=True)
    parser.add_argument("--repo", type=Path, required=True)
    parser.add_argument("--config", type=Path, required=True)
    parser.add_argument("--run-dir", type=Path, required=True)
    args = parser.parse_args()
    resolved = resolve_config(args.harness, args.repo, args.config)
    thresholds = resolved.harness_config.thresholds

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
