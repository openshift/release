#!/usr/bin/env python3
"""Run offline REL-03 contract tests against one exact harness checkout."""

import argparse
import contextlib
import io
from pathlib import Path
import subprocess
import sys
import tempfile
import unittest
from unittest import mock

import yaml

from eval_config import EvalError, HARNESS_REVISION, resolve_config  # pylint: disable=import-error
from eval_plan import artifact_name  # pylint: disable=import-error
import eval_regression  # pylint: disable=import-error


class RealHarnessContractTests(unittest.TestCase):
    """Exercise release's bridge with the pinned harness parser and scorer."""

    harness_checkout = None

    def setUp(self):
        self.temporary = tempfile.TemporaryDirectory()  # pylint: disable=consider-using-with
        self.addCleanup(self.temporary.cleanup)
        self.root = Path(self.temporary.name).resolve()
        self.repo = self.root / "consumer"
        self.repo.mkdir()
        (self.repo / "evals").mkdir()
        (self.repo / "evals/cases").mkdir()
        self.harness = self.harness_checkout

    def put_yaml(self, relative, document):
        path = self.repo / relative
        path.parent.mkdir(parents=True, exist_ok=True)
        path.write_text(yaml.safe_dump(document, sort_keys=False), encoding="utf-8")
        return path

    def profile_chain(self):
        self.put_yaml("evals/base.yaml", {
            "name": "contract-base",
            "models": {"skill": "base-model"},
            "dataset": {"path": "cases"},
            "thresholds": {
                "quality": {"min_pass_rate": 0.85, "max_error_rate": 0.5},
                "safety": {"min_mean": 0.7},
            },
            "permissions": {"labels": ["base"], "replace_labels": ["base"]},
        })
        self.put_yaml("evals/profiles/intermediate.yaml", {
            "extends": "../base.yaml",
            "models": {"skill": "intermediate-model"},
            "permissions": {"labels": ["intermediate"], "replace_labels": ["intermediate"]},
        })
        self.put_yaml("evals/profiles/ci.yaml", {
            "extends": "intermediate.yaml",
            "models": {"skill": "overlay-model"},
            "thresholds": {"quality": {"min_pass_rate": 0.75}},
            "permissions": {
                "labels": ["ci"],
                "replace_labels": ["ci"],
            },
        })
        overlay = self.repo / "evals/profiles/ci.yaml"
        # Use a literal !replace tag, which the harness owns and this test must
        # not emulate with a second YAML loader.
        overlay.write_text(
            "extends: intermediate.yaml\n"
            "models: {skill: overlay-model}\n"
            "thresholds: {quality: {min_pass_rate: 0.75}}\n"
            "permissions:\n"
            "  labels: [ci]\n"
            "  replace_labels: !replace [ci]\n",
            encoding="utf-8",
        )
        return self.repo / "evals/base.yaml", overlay

    def test_plain_config_uses_harness_model_thresholds_and_dataset_api(self):
        self.put_yaml("evals/plain.yaml", {
            "models": {"skill": "plain-model"},
            "dataset": {"path": "cases"},
            "thresholds": {"quality": {"min_pass_rate": 0.9}},
        })
        resolved = resolve_config(self.harness, self.repo, "evals/plain.yaml")
        self.assertEqual(resolved.model, "plain-model")
        self.assertEqual(resolved.settings["thresholds"]["quality"]["min_pass_rate"], 0.9)
        self.assertEqual(resolved.dataset_path, str((self.repo / "evals/cases").resolve()))
        self.assertEqual(resolved.config_chain, ("evals/plain.yaml",))

    def test_eval_name_follows_the_harness_scorer_priority(self):
        self.put_yaml("evals/named.yaml", {
            "name": "explicit-name",
            "models": {"skill": "m"},
            "dataset": {"path": "cases"},
        })
        self.put_yaml("evals/skilled.yaml", {
            "name": "explicit-name",
            "execution": {"skill": "plugin:skill"},
            "models": {"skill": "m"},
            "dataset": {"path": "cases"},
        })
        # score.py/report.py/preflight.py look under runs/<eval_name>/, where the
        # skill wins over name; the runner must agree with them, not with name.
        self.assertEqual(resolve_config(self.harness, self.repo, "evals/named.yaml").eval_name,
                         "explicit-name")
        self.assertEqual(resolve_config(self.harness, self.repo, "evals/skilled.yaml").eval_name,
                         "plugin:skill")

    def test_multi_level_overlay_merges_and_resolves_dataset_from_base(self):
        _, overlay = self.profile_chain()
        resolved = resolve_config(self.harness, self.repo, overlay)
        self.assertEqual(resolved.config, "evals/profiles/ci.yaml")
        self.assertEqual(resolved.model, "overlay-model")
        self.assertEqual(resolved.settings["thresholds"], {
            "quality": {"min_pass_rate": 0.75, "max_error_rate": 0.5},
            "safety": {"min_mean": 0.7},
        })
        self.assertEqual(resolved.dataset_path, str((self.repo / "evals/cases").resolve()))
        self.assertEqual(resolved.config_chain, (
            "evals/base.yaml", "evals/profiles/intermediate.yaml", "evals/profiles/ci.yaml"))
        merged, chain = __import__("agent_eval.config", fromlist=["load_raw"]).load_raw(overlay)
        self.assertEqual(chain[0], str((self.repo / "evals/base.yaml").resolve()))
        self.assertEqual(merged["permissions"]["labels"], ["base", "intermediate", "ci"])
        self.assertEqual(merged["permissions"]["replace_labels"], ["ci"])

    def test_two_overlays_of_one_base_keep_distinct_entry_identities(self):
        _, first_path = self.profile_chain()
        second_path = self.repo / "evals/profiles/nightly.yaml"
        second_path.write_text(
            "extends: ../base.yaml\n"
            "models: {skill: nightly-model}\n",
            encoding="utf-8",
        )
        first = resolve_config(self.harness, self.repo, first_path)
        second = resolve_config(self.harness, self.repo, second_path)
        self.assertEqual(first.config_chain[0], "evals/base.yaml")
        self.assertEqual(second.config_chain[0], "evals/base.yaml")
        self.assertEqual(first.config, "evals/profiles/ci.yaml")
        self.assertEqual(second.config, "evals/profiles/nightly.yaml")
        self.assertNotEqual(artifact_name(first.config), artifact_name(second.config))

    def test_missing_base_cycle_and_harness_depth_limit_are_reported(self):
        self.put_yaml("evals/missing.yaml", {
            "extends": "absent.yaml", "models": {"skill": "model"}})
        with self.assertRaisesRegex(EvalError, "does not exist"):
            resolve_config(self.harness, self.repo, "evals/missing.yaml")

        self.put_yaml("evals/cycle-a.yaml", {
            "extends": "cycle-b.yaml", "models": {"skill": "model"}})
        self.put_yaml("evals/cycle-b.yaml", {"extends": "cycle-a.yaml"})
        with self.assertRaisesRegex(EvalError, "cycle detected"):
            resolve_config(self.harness, self.repo, "evals/cycle-a.yaml")

        config_module = __import__("agent_eval.config", fromlist=["MAX_EXTENDS_DEPTH"])
        maximum = config_module.MAX_EXTENDS_DEPTH
        for index in range(maximum + 2):
            parent = f"chain-{index + 1}.yaml" if index < maximum + 1 else None
            document = {"models": {"skill": "model"}}
            if parent:
                document["extends"] = parent
            self.put_yaml(f"evals/depth/chain-{index}.yaml", document)
        with self.assertRaisesRegex(EvalError, "deeper than"):
            resolve_config(self.harness, self.repo, "evals/depth/chain-0.yaml")

    def test_relative_parent_reference_is_allowed_but_external_chain_is_rejected(self):
        base, overlay = self.profile_chain()
        resolved = resolve_config(self.harness, self.repo, overlay)
        self.assertEqual(resolved.config_chain[0], base.relative_to(self.repo).as_posix())

        outside = self.root / "outside.yaml"
        outside.write_text("models: {skill: outside-model}\n", encoding="utf-8")
        self.put_yaml("evals/external.yaml", {
            "extends": "../../outside.yaml", "models": {"skill": "overlay-model"}})
        with self.assertRaisesRegex(EvalError, "inside the repository"):
            resolve_config(self.harness, self.repo, "evals/external.yaml")

    def test_explicit_null_threshold_is_preserved_and_rejected(self):
        config = self.put_yaml("evals/null.yaml", {
            "models": {"skill": "model"}, "thresholds": None})
        with self.assertRaisesRegex(EvalError, "thresholds must be a mapping"):
            resolve_config(self.harness, self.repo, config)
        config_module = sys.modules["agent_eval.config"]
        raw, _ = config_module.load_raw(config)
        self.assertIsNone(raw["thresholds"])

    def test_regression_helper_uses_effective_overlay_thresholds(self):
        base, overlay = self.profile_chain()
        run_dir = self.root / "run"
        run_dir.mkdir()
        (run_dir / "summary.yaml").write_text(
            "judges:\n"
            "  quality:\n"
            "    pass_rate: 0.8\n"
            "  safety:\n"
            "    mean: 0.8\n",
            encoding="utf-8",
        )

        def score(config):
            arguments = [
                "eval_regression.py", "--harness", str(self.harness), "--repo", str(self.repo),
                "--config", str(config), "--run-dir", str(run_dir),
            ]
            with mock.patch.object(sys, "argv", arguments), contextlib.redirect_stdout(io.StringIO()):
                return eval_regression.main()

        self.assertEqual(score(overlay), 0)  # overridden minimum is 0.75
        self.assertEqual(score(base), 1)  # inherited base minimum is 0.85


def checked_harness(path):
    result = subprocess.run(
        ["git", "-C", str(path), "rev-parse", "HEAD"],
        check=True, capture_output=True, text=True, timeout=10,
    )
    actual = result.stdout.strip()
    if actual != HARNESS_REVISION:
        raise ValueError(f"expected harness {HARNESS_REVISION}, got {actual or '<empty>'}")
    if not (path / "agent_eval/config.py").is_file():
        raise ValueError(f"{path} does not contain agent_eval/config.py")
    return path


def main(argv=None):
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--harness-checkout", required=True, type=Path)
    args = parser.parse_args(argv)
    try:
        RealHarnessContractTests.harness_checkout = checked_harness(args.harness_checkout.resolve())
    except (OSError, subprocess.SubprocessError, ValueError) as error:
        parser.error(str(error))
    suite = unittest.defaultTestLoader.loadTestsFromTestCase(RealHarnessContractTests)
    result = unittest.TextTestRunner(verbosity=2).run(suite)
    return 0 if result.wasSuccessful() else 1


if __name__ == "__main__":
    sys.exit(main())
