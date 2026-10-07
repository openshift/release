#!/usr/bin/env python3
# pylint: disable=invalid-name
"""Static-analysis tests for the OPP interop recovery changes (INTEROP-9527).

These tests verify that the OPP step-registry scripts maintain the
invariants established during the recovery effort:

1. Exit-trap preservation: trap handlers must propagate the actual exit
   code (``exit ${_jrc}``) rather than swallowing it (``exit 0``).
2. XML-escaping: JUnit emitters must escape kind/message values to
   prevent malformed XML when error strings contain ``& < > " '``.
3. MCP convergence classification: the wait-mcp timeout path must
   classify timeouts as failures (``exit 1``), never exit 0 on timeout.
4. Skip-ratio-gate: the FAIL_ON_BREACH Python default must match the
   ref.yaml default; no ci-operator config may hardcode
   FAIL_ON_BREACH=true.
5. Version transition checks: product-upgrade steps must verify that
   the operator version actually changed after an upgrade.

Run from the repository root:
    python3 hack/test-opp-recovery.py
"""

from __future__ import annotations

import re
import sys
import unittest
from pathlib import Path

# Resolve the repository root (two levels up from hack/)
REPO_ROOT = Path(__file__).resolve().parent.parent
STEP_REGISTRY = REPO_ROOT / "ci-operator" / "step-registry" / "interop" / "opp"
CI_OPERATOR_CONFIG = REPO_ROOT / "ci-operator" / "config"


def _read(path: Path) -> str:
    """Read a file and return its contents as a string."""
    return path.read_text(encoding="utf-8", errors="replace")


class TestExitTrapPreservation(unittest.TestCase):
    """Verify trap handlers propagate exit codes, not ``exit 0``."""

    def _assert_no_swallowed_exit(self, path: Path, description: str) -> None:
        """Assert that the final EXIT trap does not contain ``exit 0``."""
        content = _read(path)
        # Find all EXIT trap lines
        trap_lines = [
            (i + 1, line)
            for i, line in enumerate(content.splitlines())
            if re.search(r"trap\s+'[^']*'\s+EXIT", line)
            or re.search(r'trap\s+"[^"]*"\s+EXIT', line)
        ]
        self.assertTrue(
            trap_lines,
            f"No EXIT trap found in {path.relative_to(REPO_ROOT)}",
        )
        # Check the LAST trap (the one that's active when Main runs)
        last_lineno, last_line = trap_lines[-1]
        self.assertNotIn(
            "exit 0",
            last_line,
            f"{description}: final EXIT trap at line {last_lineno} swallows "
            f"exit code with 'exit 0' — must use 'exit ${{_jrc}}' or similar "
            f"to propagate the actual exit code",
        )

    @unittest.expectedFailure  # Remove after PR #86592 merges
    def test_smoke_commands_trap(self) -> None:
        """Smoke script EXIT trap must propagate exit code, not exit 0."""
        path = STEP_REGISTRY / "smoke" / "interop-opp-smoke-commands.sh"
        if not path.exists():
            self.fail(f"{path} does not exist")
        self._assert_no_swallowed_exit(path, "smoke-commands.sh")

    @unittest.expectedFailure  # Remove after PR #86592 merges
    def test_upgrade_commands_trap(self) -> None:
        """Upgrade script EXIT trap must propagate exit code, not exit 0."""
        path = STEP_REGISTRY / "upgrade" / "interop-opp-upgrade-commands.sh"
        if not path.exists():
            self.fail(f"{path} does not exist")
        self._assert_no_swallowed_exit(path, "upgrade-commands.sh")


class TestXmlEscaping(unittest.TestCase):
    """Verify JUnit emitters XML-escape their output."""

    @unittest.expectedFailure  # Remove once _junit_emit_safe is patched
    def test_acm_junit_emit_safe_escapes(self) -> None:
        """_junit_emit_safe must call _xml_escape on kind and message."""
        path = (
            STEP_REGISTRY
            / "product-upgrade"
            / "acm"
            / "interop-opp-product-upgrade-acm-commands.sh"
        )
        if not path.exists():
            self.fail(f"{path} does not exist")
        content = _read(path)
        # Find the _junit_emit_safe function body
        match = re.search(
            r"_junit_emit_safe\(\)\s*\{(.*?)^\}",
            content,
            re.DOTALL | re.MULTILINE,
        )
        self.assertIsNotNone(
            match,
            "_junit_emit_safe function not found in acm-commands.sh",
        )
        body = match.group(1)
        # Verify _xml_escape is used for the kind attribute
        self.assertRegex(
            body,
            r'name=.*\$\(_xml_escape',
            "_junit_emit_safe must XML-escape the kind value "
            "in the testcase name= attribute",
        )
        # Verify _xml_escape is used for the message attribute
        self.assertRegex(
            body,
            r'message=.*\$\(_xml_escape',
            "_junit_emit_safe must XML-escape the message value "
            "in the failure message= attribute",
        )


class TestMcpConvergenceClassification(unittest.TestCase):
    """Verify the wait-mcp timeout path always exits non-zero."""

    @unittest.expectedFailure  # Remove after PR #86591 merges
    def test_timeout_classification_not_nonblocking(self) -> None:
        """The timeout message must not say 'non-blocking'."""
        path = STEP_REGISTRY / "wait-mcp" / "interop-opp-wait-mcp-commands.sh"
        if not path.exists():
            self.fail(f"{path} does not exist")
        content = _read(path)
        # The UPDATING+progressing branch should not call itself non-blocking
        self.assertNotRegex(
            content,
            r"(?i)non.?blocking",
            "wait-mcp timeout path must not classify as 'non-blocking' — "
            "a timeout is a failure even if cluster health checks pass",
        )

    @unittest.expectedFailure  # Remove after PR #86591 merges
    def test_timeout_exits_nonzero(self) -> None:
        """The UPDATING+progressing branch must exit 1, not exit $?."""
        path = STEP_REGISTRY / "wait-mcp" / "interop-opp-wait-mcp-commands.sh"
        if not path.exists():
            self.fail(f"{path} does not exist")
        content = _read(path)
        # Find the UPDATING case block
        updating_block = re.search(
            r"UPDATING\)(.*?);;",
            content,
            re.DOTALL,
        )
        self.assertIsNotNone(
            updating_block,
            "UPDATING case block not found in wait-mcp-commands.sh",
        )
        block = updating_block.group(1)
        # In the "progressing" sub-branch, ensure exit 1 not exit $?
        if "IsReadyCountProgressing" in block:
            progressing_section = block[: block.index("else")]
            self.assertIn(
                "exit 1",
                progressing_section,
                "UPDATING+progressing branch must 'exit 1', not 'exit $?' "
                "(a timeout should always fail the step)",
            )


class TestSkipRatioGate(unittest.TestCase):
    """Verify skip-ratio-gate configuration consistency."""

    @unittest.expectedFailure  # Remove after FAIL_ON_BREACH defaults align
    def test_fail_on_breach_default_matches_yaml(self) -> None:
        """Python default for FAIL_ON_BREACH must match ref.yaml default."""
        commands = (
            STEP_REGISTRY
            / "skip-ratio-gate"
            / "interop-opp-skip-ratio-gate-commands.sh"
        )
        ref_yaml = (
            STEP_REGISTRY
            / "skip-ratio-gate"
            / "interop-opp-skip-ratio-gate-ref.yaml"
        )
        if not commands.exists() or not ref_yaml.exists():
            self.fail("skip-ratio-gate files not found")

        # Extract Python default
        cmd_content = _read(commands)
        py_match = re.search(
            r'FAIL_ON_BREACH["\'],\s*["\'](\w+)["\']',
            cmd_content,
        )
        self.assertIsNotNone(
            py_match,
            "Could not find FAIL_ON_BREACH default in Python script",
        )
        py_default = py_match.group(1).lower()

        # Extract YAML default
        yaml_content = _read(ref_yaml)
        yaml_match = re.search(
            r'name:\s*FAIL_ON_BREACH\s*\n.*?default:\s*["\']?(\w+)',
            yaml_content,
            re.DOTALL,
        )
        if yaml_match is None:
            # Try the other YAML ordering (default before name)
            yaml_match = re.search(
                r'default:\s*["\']?(\w+)["\']?\s*\n\s*'
                r'(?:documentation:.*?\n\s*)*name:\s*FAIL_ON_BREACH',
                yaml_content,
                re.DOTALL,
            )
        self.assertIsNotNone(
            yaml_match,
            "Could not find FAIL_ON_BREACH default in ref.yaml",
        )
        yaml_default = yaml_match.group(1).lower()
        self.assertEqual(
            py_default,
            yaml_default,
            f"FAIL_ON_BREACH Python default ({py_default!r}) must match "
            f"ref.yaml default ({yaml_default!r})",
        )

    def test_no_fail_on_breach_true_in_configs(self) -> None:
        """No ci-operator config should hardcode FAIL_ON_BREACH=true."""
        if not CI_OPERATOR_CONFIG.is_dir():
            self.fail("ci-operator/config directory not found")

        violations: list[str] = []
        for yaml_path in CI_OPERATOR_CONFIG.rglob("*.yaml"):
            try:
                content = _read(yaml_path)
            except OSError:
                continue
            # Match FAIL_ON_BREACH: "true" or FAIL_ON_BREACH: true (unquoted)
            if re.search(
                r'FAIL_ON_BREACH:\s*["\']?true["\']?',
                content,
                re.IGNORECASE,
            ):
                violations.append(
                    str(yaml_path.relative_to(REPO_ROOT))
                )

        self.assertEqual(
            violations,
            [],
            f"FAIL_ON_BREACH=true found in ci-operator configs "
            f"(P5 decision: must not be set to true): {violations}",
        )


class TestVersionTransitionChecks(unittest.TestCase):
    """Verify product-upgrade steps check for version changes."""

    def _assert_version_check(self, path: Path, product: str) -> None:
        """Assert the file contains a version transition guard."""
        if not path.exists():
            self.fail(f"{path} does not exist")
        content = _read(path)
        # Look for a comparison like newVersion == currentVersion
        has_check = bool(
            re.search(r'newVersion.*==.*currentVersion', content)
            or re.search(r'version.*did not change', content, re.IGNORECASE)
        )
        self.assertTrue(
            has_check,
            f"{product} upgrade script must verify that the operator "
            f"version actually changed after upgrade",
        )

    @unittest.expectedFailure  # Remove after version-check PR merges
    def test_acm_version_transition(self) -> None:
        """ACM upgrade script must verify version actually changed."""
        path = (
            STEP_REGISTRY
            / "product-upgrade"
            / "acm"
            / "interop-opp-product-upgrade-acm-commands.sh"
        )
        self._assert_version_check(path, "ACM")

    @unittest.expectedFailure  # Remove after version-check PR merges
    def test_acs_version_transition(self) -> None:
        """ACS upgrade script must verify version actually changed."""
        path = (
            STEP_REGISTRY
            / "product-upgrade"
            / "acs"
            / "interop-opp-product-upgrade-acs-commands.sh"
        )
        self._assert_version_check(path, "ACS")


class TestProductExitPreserved(unittest.TestCase):
    """Verify that product-exit short-circuits are NOT removed.

    Per P5 Option B, the ``_EXIT_CLASS=="product" → exit 0`` block in
    ACM must be preserved.  These tests ensure it was not accidentally
    stripped.
    """

    def test_acm_product_exit_preserved(self) -> None:
        """ACM product-exit short-circuit must be preserved per P5."""
        path = (
            STEP_REGISTRY
            / "product-upgrade"
            / "acm"
            / "interop-opp-product-upgrade-acm-commands.sh"
        )
        if not path.exists():
            self.fail(f"{path} does not exist")
        content = _read(path)
        self.assertRegex(
            content,
            r'_EXIT_CLASS.*==.*"product"',
            "ACM product-exit short-circuit "
            '(_EXIT_CLASS=="product" -> exit 0) '
            "must be preserved per P5 Option B",
        )
        # Verify the product branch actually exits 0
        match = re.search(
            r'_EXIT_CLASS.*==.*"product".*?\n(.*?\n)*?.*?exit 0',
            content,
        )
        self.assertIsNotNone(
            match,
            "The product-exit branch must include 'exit 0' "
            "to short-circuit on product failures per P5 Option B",
        )


class TestEvidenceIncomplete(unittest.TestCase):
    """Verify skip-ratio-gate handles evidence-incomplete scenarios."""

    def test_evidence_incomplete_function_exists(self) -> None:
        """Skip-ratio-gate must define write_evidence_incomplete_junit."""
        path = (
            STEP_REGISTRY
            / "skip-ratio-gate"
            / "interop-opp-skip-ratio-gate-commands.sh"
        )
        if not path.exists():
            self.fail(f"{path} does not exist")
        content = _read(path)
        self.assertIn(
            "write_evidence_incomplete_junit",
            content,
            "skip-ratio-gate must have a write_evidence_incomplete_junit "
            "function for handling cases where no valid measurement is possible",
        )

    def test_evidence_incomplete_on_no_files(self) -> None:
        """Script must emit EVIDENCE_INCOMPLETE when no XML files found."""
        path = (
            STEP_REGISTRY
            / "skip-ratio-gate"
            / "interop-opp-skip-ratio-gate-commands.sh"
        )
        if not path.exists():
            self.fail(f"{path} does not exist")
        content = _read(path)
        self.assertIn(
            "EVIDENCE-INCOMPLETE",
            content,
            "skip-ratio-gate must emit EVIDENCE-INCOMPLETE markers",
        )


if __name__ == "__main__":
    # Use a test runner that works well in CI
    loader = unittest.TestLoader()
    suite = loader.loadTestsFromModule(sys.modules[__name__])
    runner = unittest.TextTestRunner(verbosity=2)
    result = runner.run(suite)
    sys.exit(0 if result.wasSuccessful() else 1)
