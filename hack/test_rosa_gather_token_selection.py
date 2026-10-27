#!/usr/bin/env python3
"""Offline actual-step fixtures: python3 hack/test_rosa_gather_token_selection.py.

Only literal credential and temporary paths are relocated in the delivered script.
Downloads, OCM, backplane and oc are replaced with local fixtures; no real credentials
or network access are used. Selection assertions record matches, never token values.
"""

import io
import os
from pathlib import Path
import shlex
import shutil
import subprocess
import sys
import tarfile
import tempfile
import unittest


REPOSITORY = Path(__file__).resolve().parents[1]
SCRIPT = REPOSITORY / (
    "ci-operator/step-registry/rosa/e2e/gather-cluster-diagnostics/"
    "rosa-e2e-gather-cluster-diagnostics-commands.sh")
TOKENS = ("FAKE_OCM_TOKEN_NOT_REAL", "FAKE_MEMBER_TOKEN_NOT_REAL", "FAKE_FILE_TOKEN_NOT_REAL")


def mock_command(command, arguments):
    base = Path(os.environ["FIXTURE_DIR"])
    with (base / "calls").open("a", encoding="utf-8") as calls:
        calls.write(command + "\n")
    if command == "curl":
        destination = Path(arguments[arguments.index("-o") + 1])
        if destination.name == "ocm":
            shutil.copyfile(base / "bin/ocm", destination)
        else:
            content = (base / "bin/ocm-backplane").read_bytes()
            with tarfile.open(destination, "w:gz") as archive:
                entry = tarfile.TarInfo("ocm-backplane")
                entry.size = len(content)
                entry.mode = 0o755
                archive.addfile(entry, io.BytesIO(content))
        return 0
    if command == "ocm":
        if arguments[:1] != ["login"]:
            raise AssertionError("Unexpected OCM operation")
        selected = "--token=" + os.environ["EXPECTED_TOKEN"]
        if selected not in arguments:
            raise AssertionError("Wrong token selected")
        with (base / "calls").open("a", encoding="utf-8") as calls:
            calls.write("login-match\n")
        if os.environ["FAIL_LOGIN"] == "true":
            print(os.environ["EXPECTED_TOKEN"], file=sys.stderr)
            return 1
        return 0
    if command in ("ocm-backplane", "oc"):
        return 0
    raise AssertionError("Unexpected fixture command")


class GatherTokenSelectionTests(unittest.TestCase):
    def run_fixture(self, tracing, credentials=(None, None), expected="", fail=False):
        sourced, individual = credentials
        with tempfile.TemporaryDirectory() as directory:
            base = Path(directory)
            for name in ("credentials", "tmp", "bin", "home", "shared", "artifacts"):
                (base / name).mkdir()
            (base / "shared/cluster-id").write_text("fixture-cluster\n", encoding="utf-8")
            if sourced is not None:
                (base / "credentials/ocm-tokens").write_text(sourced, encoding="utf-8")
            if individual is not None:
                (base / "credentials/ocm_token").write_text(individual, encoding="utf-8")
            for command in ("curl", "ocm", "ocm-backplane", "oc"):
                executable = base / "bin" / command
                executable.write_text(
                    "#!/bin/bash\nexec " + shlex.join([
                        sys.executable, str(Path(__file__).resolve()), "mock", command,
                    ]) + ' "$@"\n', encoding="utf-8")
                executable.chmod(0o755)
            script = base / "step.sh"
            script.write_text(
                SCRIPT.read_text(encoding="utf-8")
                .replace("/tmp/", str(base / "tmp") + "/")
                .replace("/usr/local/cs-qe-credentials", str(base / "credentials"))
                + '\nprintf "%s" "$-" > "${FIXTURE_DIR}/trace-state"\n',
                encoding="utf-8")
            environment = {
                "PATH": str(base / "bin") + ":/usr/bin:/bin",
                "HOME": str(base / "home"),
                "SHARED_DIR": str(base / "shared"),
                "ARTIFACT_DIR": str(base / "artifacts"),
                "FIXTURE_DIR": str(base),
                "EXPECTED_TOKEN": expected,
                "FAIL_LOGIN": "true" if fail else "false",
            }
            result = subprocess.run(
                ["bash", *(["-x"] if tracing else []), str(script)],
                env=environment, capture_output=True, text=True, timeout=30, check=False)
            self.assertEqual(result.returncode, 0)
            output = result.stdout + result.stderr
            self.assertEqual("+ cleanup\n" in result.stderr, tracing)
            for token in TOKENS:
                self.assertNotIn(token, output)
                for artifact in (base / "artifacts").rglob("*"):
                    self.assertNotIn(token, str(artifact.relative_to(base)))
                    if artifact.is_file():
                        self.assertNotIn(token.encode(), artifact.read_bytes())
            calls = (base / "calls").read_text(encoding="utf-8").splitlines()
            self.assertEqual(calls.count("ocm"), int(bool(expected)))
            self.assertEqual(calls.count("login-match"), int(bool(expected)))
            if not expected:
                self.assertIn("No OCM token found", output)
            elif fail:
                self.assertIn("OCM login failed", output)
            else:
                self.assertIn("OCM login successful", output)
                self.assertIn("ocm-backplane", calls)
                self.assertIn("oc", calls)
                state = (base / "trace-state").read_text(encoding="utf-8")
                self.assertEqual("x" in state, tracing)
            if not expected or fail:
                self.assertNotIn("ocm-backplane", calls)
                self.assertNotIn("oc", calls)

    def test_selection_and_secret_safe_tracing(self):
        cases = (
            ("ocm", f'export OCM_TOKEN={TOKENS[0]}\n', None, TOKENS[0]),
            ("member", f'export ORG_MEMBER_TOKEN={TOKENS[1]}\n', None, TOKENS[1]),
            ("individual", None, TOKENS[2] + "\n", TOKENS[2]),
            ("both", f'OCM_TOKEN={TOKENS[0]}\nORG_MEMBER_TOKEN={TOKENS[1]}\n',
             None, TOKENS[0]),
            ("all", f'OCM_TOKEN={TOKENS[0]}\nORG_MEMBER_TOKEN={TOKENS[1]}\n',
             TOKENS[2], TOKENS[0]),
            ("file-before-member", f'ORG_MEMBER_TOKEN={TOKENS[1]}\n',
             TOKENS[2], TOKENS[2]),
            ("empty-ocm", f'OCM_TOKEN=""\nORG_MEMBER_TOKEN={TOKENS[1]}\n',
             None, TOKENS[1]),
            ("empty-file", f'ORG_MEMBER_TOKEN={TOKENS[1]}\n', "", TOKENS[1]),
            ("source-failure", f'ORG_MEMBER_TOKEN={TOKENS[1]}\n'
             'printf "%s" "$ORG_MEMBER_TOKEN" >&2\nreturn 1\n',
             None, TOKENS[1]),
            ("missing", None, None, ""),
            ("empty", 'OCM_TOKEN=""\nORG_MEMBER_TOKEN=""\n', "", ""),
        )
        for tracing in (False, True):
            for name, sourced, individual, expected in cases:
                with self.subTest(case=name, tracing=tracing):
                    self.run_fixture(tracing, (sourced, individual), expected)

    def test_authentication_failure_is_best_effort(self):
        for tracing in (False, True):
            with self.subTest(tracing=tracing):
                self.run_fixture(tracing, (f'ORG_MEMBER_TOKEN={TOKENS[1]}\n', None),
                                 expected=TOKENS[1], fail=True)


if __name__ == "__main__":
    if sys.argv[1:2] == ["mock"]:
        sys.exit(mock_command(sys.argv[2], sys.argv[3:]))
    unittest.main(verbosity=2)
