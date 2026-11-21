#!/usr/bin/env python3
"""Offline regression tests: python3 hack/test_rosa_install_timing_markers.py.

The gather-extra step builds job_metrics.json by expanding a query list inside a
generated helper that runs under 'set -o nounset'. Every query line is gated on
shell variables derived solely from four marker files in SHARED_DIR:
TEST_TIME_INSTALL_START, TEST_TIME_INSTALL_END, TEST_TIME_TEST_START and
TEST_TIME_TEST_END. A line naming a variable that no marker defined is skipped,
so missing markers silently remove queries instead of failing the step.

ROSA Classic jobs published no markers, which reduced job_metrics.json to the two
queries that need nothing but the always-defined overall timestamp and dropped
all seven alert queries. These tests pin that behaviour to the real generator
extracted from the real step script, and assert the ROSA producer steps now emit
each marker with the right lifecycle. No cluster, network or credential is used.
"""

import os
import re
import subprocess
import tempfile
import unittest
from pathlib import Path


REPOSITORY = Path(__file__).resolve().parents[1]
REGISTRY = REPOSITORY / "ci-operator/step-registry"

CONSUMER = REGISTRY / "gather/extra/gather-extra-commands.sh"
PROVISION = REGISTRY / "rosa/cluster/provision/rosa-cluster-provision-commands.sh"
WAIT_OPERATORS = (
    REGISTRY
    / "rosa/cluster/wait-ready/operators/rosa-cluster-wait-ready-operators-commands.sh"
)
CONFORMANCE = (
    REGISTRY
    / "rosa/aws/sts/conformance/test/rosa-aws-sts-conformance-test-commands.sh"
)

MARKERS = (
    "TEST_TIME_INSTALL_START",
    "TEST_TIME_INSTALL_END",
    "TEST_TIME_TEST_START",
    "TEST_TIME_TEST_END",
)

# The two queries a ROSA Classic run published while no marker existed. They are
# the only ones whose text needs nothing beyond the overall timestamp, which the
# generator always defines by falling back to the current time.
BASELINE_QUERIES = {
    "cluster:usage:memory:crio:total:avg",
    "cluster:usage:memory:kubelet:total:avg",
}

ALERT_QUERIES = {
    "cluster:alerts:install:firing:seconds:severity",
    "cluster:alerts:install:pending:seconds:severity",
    "cluster:alerts:test:firing:seconds:severity",
    "cluster:alerts:test:pending:seconds:severity",
    "cluster:alerts:total:firing:distinct:severity",
    "cluster:alerts:total:firing:seconds:severity",
    "cluster:alerts:total:pending:seconds:severity",
}

GENERATOR_OPEN = "cat >/tmp/generate.sh <<'GENERATE'"
GENERATOR_CLOSE = "GENERATE"


def extract_generator():
    """Return the metrics generator exactly as the gather-extra step writes it."""
    lines = CONSUMER.read_text(encoding="utf-8").splitlines()
    try:
        start = lines.index(GENERATOR_OPEN) + 1
    except ValueError as missing:
        raise AssertionError(
            f"{CONSUMER} no longer contains {GENERATOR_OPEN!r}; the metrics "
            "generator moved and this test needs updating"
        ) from missing
    for offset, line in enumerate(lines[start:]):
        if line == GENERATOR_CLOSE:
            return "\n".join(lines[start : start + offset]) + "\n"
    raise AssertionError(f"unterminated generator heredoc in {CONSUMER}")


def emitted_queries(markers):
    """Run the real generator offline and return the metric names it emits.

    'markers' maps marker names to timestamps. A marker left out is passed as the
    empty string, which is what the step produces when the file is absent.
    """
    environment = dict(os.environ)
    for marker in MARKERS:
        environment[marker] = str(markers.get(marker, ""))

    with tempfile.TemporaryDirectory() as directory:
        # The generator keeps its scratch files at hardcoded /tmp paths. Redirect
        # only those into the sandbox so concurrent runs, or leftovers owned by
        # another user, cannot change the result. The gating logic under test is
        # untouched; assert the redirection actually applied so this cannot rot
        # into silently testing the unmodified /tmp behaviour.
        body, scratch = re.subn(r"/tmp/(queries_resolved|queries)\b", f"{directory}/\\1", extract_generator())
        if not scratch:
            raise AssertionError("generator no longer uses /tmp scratch paths")

        generator = Path(directory) / "generate.sh"
        generator.write_text(body, encoding="utf-8")
        completed = subprocess.run(
            ["bash", str(generator)],
            env=environment,
            capture_output=True,
            text=True,
            check=True,
            cwd=directory,
        )

    # The generator emits a script that embeds the resolved queries as
    # '<timestamp> <name> <promql>' lines inside a quoted heredoc.
    names = set()
    for line in completed.stdout.splitlines():
        match = re.match(r"^\d+\s+(\S+)\s+\S", line)
        if match:
            names.add(match.group(1))
    return names


ALL_MARKERS = {
    "TEST_TIME_INSTALL_START": 1000,
    "TEST_TIME_INSTALL_END": 2000,
    "TEST_TIME_TEST_START": 2000,
    "TEST_TIME_TEST_END": 3000,
}


class ConsumerQueryGeneration(unittest.TestCase):
    """The real generator must react to markers exactly as observed in CI."""

    def test_without_markers_only_baseline_queries_survive(self):
        # BASELINE_QUERIES and ALERT_QUERIES are disjoint, so this equality
        # already proves no alert query survives; a separate check would be
        # tautological.
        self.assertEqual(
            emitted_queries({}),
            BASELINE_QUERIES,
            "a ROSA run without markers must reproduce the published baseline",
        )

    def test_all_markers_restore_every_alert_query(self):
        emitted = emitted_queries(ALL_MARKERS)
        self.assertTrue(
            ALERT_QUERIES.issubset(emitted),
            f"missing alert queries: {sorted(ALERT_QUERIES - emitted)}",
        )
        self.assertTrue(BASELINE_QUERIES.issubset(emitted))

    def test_install_markers_alone_are_not_sufficient(self):
        """Guards the assumption that install markers alone fix job_metrics.json."""
        install_only = {
            "TEST_TIME_INSTALL_START": 1000,
            "TEST_TIME_INSTALL_END": 2000,
        }
        emitted = emitted_queries(install_only)
        missing = ALERT_QUERIES - emitted
        self.assertTrue(
            missing,
            "install markers alone must not be able to emit every alert query; "
            "if this fails the test-phase markers may no longer be required",
        )
        self.assertTrue(emitted & ALERT_QUERIES, "install markers must help")

    def test_every_marker_widens_the_query_set(self):
        """Each marker pair must be load-bearing, so none is dead weight."""
        baseline = emitted_queries({})
        full = emitted_queries(ALL_MARKERS)
        self.assertLess(len(baseline), len(full))
        for pair in (
            ("TEST_TIME_INSTALL_START", "TEST_TIME_INSTALL_END"),
            ("TEST_TIME_TEST_START", "TEST_TIME_TEST_END"),
        ):
            partial = {k: v for k, v in ALL_MARKERS.items() if k not in pair}
            self.assertLess(
                len(emitted_queries(partial)),
                len(full),
                f"dropping {pair} must reduce the emitted queries",
            )


class ProducerMarkerLifecycle(unittest.TestCase):
    """The ROSA steps must publish each marker at the right point."""

    def test_provision_publishes_install_start_before_creating_the_cluster(self):
        script = PROVISION.read_text(encoding="utf-8")
        self.assertIn('> "${SHARED_DIR}/TEST_TIME_INSTALL_START"', script)
        marker = script.index("TEST_TIME_INSTALL_START")
        create = script.index('cmd="rosa create cluster')
        self.assertLess(
            marker, create, "install start must precede cluster creation"
        )

    def test_wait_ready_operators_publishes_install_end_on_success_only(self):
        """The write must sit inside the success conditional, not merely after it.

        Checking text order alone would still pass if the write were moved below
        the closing 'fi', where it would run after a failed install too.
        """
        lines = WAIT_OPERATORS.read_text(encoding="utf-8").splitlines()
        self.assertIn(
            '> "${SHARED_DIR}/TEST_TIME_INSTALL_END"', "\n".join(lines)
        )

        guard = next(
            index
            for index, line in enumerate(lines)
            if line.strip() == 'if [[ -z "${check_failed}" ]]; then'
            and 'log "All cluster operators are Available' in lines[index + 1]
        )
        marker = next(
            index
            for index, line in enumerate(lines)
            if "TEST_TIME_INSTALL_END" in line
        )
        self.assertLess(guard, marker, "install end belongs after the guard")

        # A top-level 'fi' between the guard and the write would mean the write
        # escaped the conditional.
        between = lines[guard + 1 : marker]
        self.assertNotIn(
            "fi", [line.rstrip() for line in between],
            "install end escaped the success-only conditional",
        )
        self.assertTrue(
            lines[marker].startswith("  "),
            "install end must be indented inside the conditional",
        )

    def test_conformance_publishes_test_start_before_running_the_suite(self):
        script = CONFORMANCE.read_text(encoding="utf-8")
        self.assertIn('> "${SHARED_DIR}/TEST_TIME_TEST_START"', script)
        marker = script.index("TEST_TIME_TEST_START")
        # Anchor on the scored suite invocation, not the earlier --dry-run the
        # step uses only to expand TEST_SKIPS. The measured test phase is the
        # real run, so the marker belongs between the two.
        run = script.index('openshift-tests run "${TEST_SUITE}"')
        dry_run = script.index("openshift-tests run --dry-run")
        self.assertLess(dry_run, marker, "test start follows skip expansion")
        self.assertLess(marker, run, "test start must precede the scored suite")

    def test_conformance_publishes_test_end_from_an_exit_trap(self):
        script = CONFORMANCE.read_text(encoding="utf-8")
        self.assertRegex(
            script,
            r"trap '[^']*TEST_TIME_TEST_END[^']*' EXIT",
            "test end must come from an EXIT trap so failures are still recorded",
        )

    def test_marker_writes_tolerate_failure(self):
        """A read-only or full SHARED_DIR must never fail a step."""
        for path, marker in (
            (PROVISION, "TEST_TIME_INSTALL_START"),
            (WAIT_OPERATORS, "TEST_TIME_INSTALL_END"),
            (CONFORMANCE, "TEST_TIME_TEST_START"),
            (CONFORMANCE, "TEST_TIME_TEST_END"),
        ):
            writes = [
                line.strip()
                for line in path.read_text(encoding="utf-8").splitlines()
                if marker in line and "date " in line
            ]
            self.assertTrue(
                writes, f"{path.name}: no marker write found for {marker}"
            )
            # Check every write, not just the first: a later unguarded write of
            # the same marker would still be able to fail the step.
            for write in writes:
                # For a trap, test the quoted body; otherwise the line itself.
                trapped = re.match(r"^trap\s+'(.*)'\s+\w+$", write)
                statement = trapped.group(1) if trapped else write
                self.assertTrue(
                    statement.rstrip().endswith("|| :"),
                    f"{path.name}: unguarded marker write: {write}",
                )


class ConformanceExitSemantics(unittest.TestCase):
    """The added trap must not disturb the step's exit status."""

    def _harness(self, body):
        """Run the real marker statements from the conformance step around a body."""
        script = CONFORMANCE.read_text(encoding="utf-8")
        statements = [
            line.strip()
            for line in script.splitlines()
            if ("TEST_TIME_TEST_START" in line or "TEST_TIME_TEST_END" in line)
            and line.strip().startswith(("trap ", "date "))
        ]
        self.assertEqual(
            len(statements), 2, f"expected two marker statements, got {statements}"
        )

        with tempfile.TemporaryDirectory() as directory:
            harness = Path(directory) / "harness.sh"
            harness.write_text(
                "#!/bin/bash\nset -o nounset\nset -o errexit\nset -o pipefail\n"
                + "\n".join(statements)
                + "\n"
                + body
                + "\n",
                encoding="utf-8",
            )
            completed = subprocess.run(
                ["bash", str(harness)],
                env={**os.environ, "SHARED_DIR": directory},
                capture_output=True,
                text=True,
                check=False,
                cwd=directory,
            )
            written = {
                marker: (Path(directory) / marker).exists()
                for marker in ("TEST_TIME_TEST_START", "TEST_TIME_TEST_END")
            }
            return completed.returncode, written

    def test_successful_run_records_both_markers_and_exit_zero(self):
        code, written = self._harness("exit 0")
        self.assertEqual(code, 0)
        self.assertTrue(written["TEST_TIME_TEST_START"])
        self.assertTrue(written["TEST_TIME_TEST_END"])

    def test_failed_run_still_records_the_end_marker(self):
        code, written = self._harness("exit 3")
        self.assertEqual(code, 3, "the trap must not alter the exit status")
        self.assertTrue(
            written["TEST_TIME_TEST_END"],
            "the end marker must survive a failing suite",
        )

    def test_errexit_abort_still_records_the_end_marker(self):
        code, written = self._harness("false\necho unreachable")
        self.assertNotEqual(code, 0)
        self.assertTrue(written["TEST_TIME_TEST_END"])


if __name__ == "__main__":
    unittest.main()
