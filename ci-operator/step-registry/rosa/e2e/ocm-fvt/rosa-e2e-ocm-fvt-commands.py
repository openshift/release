#!/usr/bin/env python3
"""Run upstream artifact assertions with the current component delivery fixture."""

import importlib.util
import os
from pathlib import Path
import stat
import subprocess
import sys
import unittest


sys.dont_write_bytecode = True
REPOSITORY = Path(__file__).resolve().parents[5]
STEP = Path(__file__).resolve().parent
SPEC = importlib.util.spec_from_file_location("upstream_rosa_artifacts", REPOSITORY / "hack/test_rosa_ocm_fvt_artifacts.py")
UPSTREAM = importlib.util.module_from_spec(SPEC)
SPEC.loader.exec_module(UPSTREAM)
SECRET = UPSTREAM.SECRET
DIGEST = UPSTREAM.DIGEST


def fixture_output(base):
    recorded = base / "output-path"
    return Path(recorded.read_text(encoding="utf-8")) if recorded.exists() else base / "artifacts/ocm-fvt-results"


def mock_command(command, arguments):
    base = Path(os.environ["FIXTURE_DIR"])
    case = os.environ["FIXTURE_CASE"]
    published = base / "artifacts/ocm-fvt-results"
    if command == "podman" and arguments[0] == "run":
        mount = next(argument for argument in arguments if argument.endswith(":/ocm-backend-tests/output:z"))
        output = Path(mount.removesuffix(":/ocm-backend-tests/output:z"))
        if not output.is_relative_to(base) or published.exists() or published.is_symlink():
            raise AssertionError("Unexpected fixture output location")
        (base / "output-path").write_text(str(output), encoding="utf-8")
        output.rename(published)
        try:
            return UPSTREAM.mock_command(command, arguments)
        finally:
            if published.exists() or published.is_symlink():
                metadata = published.lstat()
                if stat.S_ISDIR(metadata.st_mode):
                    mode = stat.S_IMODE(metadata.st_mode)
                    published.chmod(mode | stat.S_IWUSR | stat.S_IXUSR)
                    published.rename(output)
                    output.chmod(mode)
                else:
                    published.rename(output)
    if command == "find" and case == "find-failure" and arguments == [
            str(fixture_output(base)), "-type", "f", "-name", "report.xml", "-print0"]:
        arguments = [str(published), *arguments[1:]]
    if command == "python3" and case == "collector-failure" and arguments == [
            str(base / "shared/ocm-fvt-artifacts.py"), "metadata", str(fixture_output(base)),
            str(base / "artifacts/ocm-fvt-artifact-metadata.json")]:
        arguments = ["-", str(published), arguments[-1]]
    return UPSTREAM.mock_command(command, arguments)


class ArtifactFixture(UPSTREAM.ArtifactFixture):
    def setUp(self):
        super().setUp()
        subprocess.run([sys.executable, str(STEP / "prepare/rosa-e2e-ocm-fvt-prepare-commands.py")],
                       check=True, timeout=30, env={**os.environ, "SHARED_DIR": str(self.shared)})
        for command in ("podman", "find", "python3"):
            (self.bin / command).write_text(
                f'#!/bin/bash\nexec "{sys.executable}" "{Path(__file__).resolve()}" '
                f'--mock {command} "$@"\n', encoding="utf-8")

    def tearDown(self):
        output = fixture_output(self.base)
        if output.is_dir() and not output.is_symlink():
            output.chmod(0o700)
            result = output / "test-result-fixture"
            if result.is_dir():
                result.chmod(0o700)
        super().tearDown()


class ArtifactMetadataTests(ArtifactFixture, UPSTREAM.ArtifactMetadataTests):
    """Exercise upstream metadata assertions through prepared helper delivery."""


class ArtifactSafetyTests(ArtifactFixture, UPSTREAM.ArtifactSafetyTests):
    """Exercise upstream safety assertions against the staged producer output."""


class ArtifactPostprocessingTests(ArtifactFixture, UPSTREAM.ArtifactPostprocessingTests):
    """Exercise upstream failure and cleanup assertions through current helpers."""


if __name__ == "__main__":
    if sys.argv[1:2] == ["--mock"]:
        sys.exit(mock_command(sys.argv[2], sys.argv[3:]))
    unittest.main()
