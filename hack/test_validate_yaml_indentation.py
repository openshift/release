#!/usr/bin/env python3

import importlib.util
from pathlib import Path
import tempfile
import unittest


SPEC = importlib.util.spec_from_file_location(
    "validate_yaml_indentation",
    Path(__file__).with_name("validate-yaml-indentation.py"),
)
VALIDATOR = importlib.util.module_from_spec(SPEC)
SPEC.loader.exec_module(VALIDATOR)


class YAMLStructureTests(unittest.TestCase):
    def test_ci_operator_postsubmit_boolean(self):
        for enabled in (True, False):
            for filename in ("config.yaml", "jobs.yaml"):
                with self.subTest(enabled=enabled, filename=filename):
                    config = {"tests": [{"as": "example", "postsubmit": enabled}]}
                    self.assertEqual(
                        VALIDATOR.validate_yaml_structure(filename, config), [],
                    )

    def test_malformed_postsubmit_remains_rejected(self):
        cases = {
            "prow_repository_jobs": {"postsubmit": {"org/repo": []}},
            "root_boolean": {"postsubmit": True},
            "nested_boolean": {"job": {"postsubmit": True}},
            "prow_job": {"postsubmits": {"org/repo": [{"postsubmit": True}]}},
            "tests_mapping": {"tests": {"as": "example", "postsubmit": True}},
            "unnamed_test": {"tests": [{"postsubmit": True}]},
            "invalid_test_name": {"tests": [{"as": 1, "postsubmit": True}]},
            "nested_tests": {"job": {"tests": [{"as": "example", "postsubmit": True}]}},
            "nested_test_field": {"tests": [{"as": "example", "steps": {"postsubmit": True}}]},
        }
        for value in ("true", 1, None, [], {}):
            cases[f"invalid_value_{value!r}"] = {
                "tests": [{"as": "example", "postsubmit": value}],
            }
        for key in (0, -1, True, "example"):
            cases[f"tests_mapping_key_{key!r}"] = {
                "tests": {key: {"as": "example", "postsubmit": True}},
            }
        for name, config in cases.items():
            with self.subTest(name=name):
                errors = VALIDATOR.validate_yaml_structure("config.yaml", config)
                self.assertTrue(any(
                    "'postsubmit' should be 'postsubmits'" in error
                    for error in errors
                ), errors)

    def test_valid_prow_postsubmits(self):
        config = {"postsubmits": {"org/repo": [{"name": "example", "decorate": True}]}}
        self.assertEqual(VALIDATOR.validate_yaml_structure("jobs.yaml", config), [])

    def test_other_typos_and_invalid_types_remain_rejected(self):
        for field, value, expected in (
            ("presubmit", {}, "'presubmit' should be 'presubmits'"),
            ("periodic", [], "'periodic' should be 'periodics'"),
            ("alwaysRun", True, "'alwaysRun' should be 'always_run'"),
            ("skipReport", True, "'skipReport' should be 'skip_report'"),
            ("optional", "true", "Field 'optional' should be bool"),
            ("decorate", "true", "Field 'decorate' should be bool"),
        ):
            with self.subTest(field=field):
                config = {"tests": [{"as": "example", "postsubmit": True, field: value}]}
                errors = VALIDATOR.validate_yaml_structure("config.yaml", config)
                self.assertTrue(any(expected in error for error in errors), errors)

    def test_syntax_and_indentation_errors_remain_rejected(self):
        with tempfile.TemporaryDirectory() as directory:
            filename = Path(directory) / "config.yaml"
            filename.write_text("tests: [\n", encoding="utf-8")
            errors, _ = VALIDATOR.validate_yaml_syntax(filename)
            self.assertTrue(any("YAML syntax error" in error for error in errors))
            filename.write_text("tests:\n\t- as: example\n", encoding="utf-8")
            errors, _ = VALIDATOR.validate_yaml_indentation(filename)
            self.assertTrue(errors)


if __name__ == "__main__":
    unittest.main()
