#!/usr/bin/env python3
"""Regression tests for the shell around the Classic IDP resync parser.

classic_idp_parser_test.py covers the parser itself. The failures these cover are in the
shell: an `errexit` abort that stops the step before it collects anything, a report that is
never written, a bound applied silently, or a query budget that outlives the step timeout.
None of them are visible to the parser, and all of them end with an artifact that is absent
or reads as "no resync ran" - the one reading the step promises it will never produce.

The scripts are run as shipped, with `curl`, `mktemp` and `date` replaced on PATH so a test
never reaches the network, and with the credential mount relocated into the sandbox.

Run with:
    make test-classic-idp-parser
    python3 -m unittest discover -s hack/classic-idp-telemetry -p '*_test.py'
"""

import json
import os
import shutil
import subprocess
import tempfile
import unittest
from pathlib import Path

REPO = Path(__file__).resolve().parents[2]
STEP = (REPO / "ci-operator/step-registry/rosa/e2e/collect-cs-telemetry"
        / "rosa-e2e-collect-cs-telemetry-commands.sh")
FVT = (REPO / "ci-operator/step-registry/rosa/e2e/ocm-fvt"
       / "rosa-e2e-ocm-fvt-commands.sh")
CREDENTIAL_MOUNT = "/usr/local/rhobs-oidc"
REPORT = "classic-idp-resync-events.json"

# A Loki answer with no events, used wherever the response itself is not what is under test.
EMPTY_RESPONSE = '{"status":"success","data":{"result":[]}}'

# curl is called twice over: once without -o for the token, and once per query with -o. The
# stub answers the token request on stdout and writes RESPONSE_BODY to the query's -o path,
# so no test needs a network or a credential.
CURL_STUB = r"""#!/bin/bash
out=""; prev=""
for arg in "$@"; do [[ "$prev" == "-o" ]] && out="$arg"; prev="$arg"; done
if [[ -z "$out" ]]; then echo '{"access_token":"stub-token"}'; exit 0; fi
case "$*" in
  *"ROSA HCP"*) printf '%s' "${HCP_BODY:-$RESPONSE_BODY}" > "$out" ;;
  *) printf '%s' "$RESPONSE_BODY" > "$out" ;;
esac
exit 0
"""

MKTEMP_FAILS_FOR_DIRECTORIES = """#!/bin/bash
[[ "$*" == *-d* ]] && {{ echo "mktemp: failed to create directory" >&2; exit 1; }}
exec {real} "$@"
"""

# A clock that advances STEP_SECONDS on every reading, so a budget measured in seconds runs
# out part-way through the selector loop without a test having to wait for it.
CLOCK_STUB = """#!/bin/bash
if [[ "$*" == "+%s" ]]; then
  ticks=$(cat "$CLOCK_FILE" 2>/dev/null || echo 0)
  echo $((ticks + 1)) > "$CLOCK_FILE"
  echo $((1800000000 + ticks * STEP_SECONDS))
  exit 0
fi
exec {real} "$@"
"""

# The first query answers with an empty body, the rest answer normally.
CURL_STUB_EMPTY_FIRST = r"""#!/bin/bash
out=""; prev=""
for arg in "$@"; do [[ "$prev" == "-o" ]] && out="$arg"; prev="$arg"; done
if [[ -z "$out" ]]; then echo '{"access_token":"stub-token"}'; exit 0; fi
case "$*" in
  *"ROSA HCP"*) printf '%s' "$RESPONSE_BODY" > "$out"; exit 0 ;;
esac
if [[ -e "$MARKER_FILE" ]]; then printf '%s' "$RESPONSE_BODY" > "$out"; else : > "$out"; fi
touch "$MARKER_FILE"
exit 0
"""

CLUSTER_IDS = [f"abcdefghij012345678{n}" for n in range(10)]


def _require(*binaries):
    """Fail, rather than skip, on a missing binary. A suite that quietly skips itself
    reports a green presubmit while covering nothing, which is worse than a red one.
    `curl` is deliberately not required: every test replaces it on PATH."""
    missing = [b for b in binaries if shutil.which(b) is None]
    if missing:
        raise AssertionError(f"required by this suite but not on PATH: {', '.join(missing)}")


class StepCase(unittest.TestCase):
    """Runs the collection step with its outside world stubbed out."""

    @classmethod
    def setUpClass(cls):
        _require("bash", "mktemp", "date")
        if not STEP.is_file():
            raise unittest.SkipTest(f"{STEP} is not in this checkout")

    def setUp(self):
        self.work = Path(tempfile.mkdtemp())
        self.addCleanup(shutil.rmtree, self.work, True)
        self.shared = self.work / "shared"
        self.artifacts = self.work / "artifacts"
        self.bin = self.work / "bin"
        credentials = self.work / "credentials"
        for directory in (self.shared, self.artifacts, self.bin, credentials):
            directory.mkdir()
        (credentials / "client_id").write_text("stub-id\n")
        (credentials / "client_secret").write_text("stub-secret\n")
        (credentials / "oidc_issuer_url").write_text("https://issuer.invalid/token\n")
        # The step reads its credentials from a fixed mount path. Point it at the sandbox
        # instead; nothing else about the script is changed.
        self.script = self.work / "step.sh"
        self.script.write_text(STEP.read_text().replace(CREDENTIAL_MOUNT, str(credentials)))
        self.stub("curl", CURL_STUB)

    def stub(self, name, body):
        path = self.bin / name
        path.write_text(body)
        path.chmod(0o755)

    def selectors(self, *cluster_ids, handoff="cluster-id"):
        (self.shared / handoff).write_text("".join(f"{c}\n" for c in cluster_ids))

    def run_step(self, response_body=EMPTY_RESPONSE, **env):
        environment = dict(os.environ)
        environment.update({"PATH": f"{self.bin}{os.pathsep}{os.environ['PATH']}",
                            "SHARED_DIR": str(self.shared),
                            "ARTIFACT_DIR": str(self.artifacts),
                            "RESPONSE_BODY": response_body,
                            "MARKER_FILE": str(self.work / "marker")})
        environment.update(env)
        return subprocess.run(["bash", str(self.script)], capture_output=True, text=True,
                              env=environment, check=False)

    def report(self):
        path = self.artifacts / REPORT
        self.assertTrue(path.is_file(),
                        f"{REPORT} was not written; a consumer cannot tell this apart from "
                        f"the step never having run")
        return json.loads(path.read_text())

    # ---- errexit must not cut the collection short ----------------------------------
    def test_unreadable_hcp_body_does_not_stop_classic_collection(self):
        # A 200 whose body the HCP parser cannot read used to end the step through errexit,
        # before any Classic query or report.
        self.selectors(CLUSTER_IDS[0])
        result = self.run_step(HCP_BODY="this is not json")
        self.assertEqual(result.returncode, 0, result.stderr)
        self.assertIn("HCP telemetry parse failed", result.stdout)
        self.assertEqual(self.report()["collection"]["status"], "no_events_in_window")

    def test_absent_scratch_reports_a_status_and_does_not_fail_the_step(self):
        # With no scratch directory there is nowhere to hold the raw response, so Classic
        # collection is skipped - but skipped is a status a consumer has to be able to read,
        # and the skip must not take the HCP report down with it.
        self.stub("mktemp", MKTEMP_FAILS_FOR_DIRECTORIES.format(real=shutil.which("mktemp")))
        self.selectors(CLUSTER_IDS[0])
        result = self.run_step()
        self.assertEqual(result.returncode, 0, result.stderr)
        self.assertNotIn("Permission denied", result.stderr)
        self.assertTrue((self.artifacts / "cs-telemetry.log").is_file(), result.stderr)
        collection = self.report()["collection"]
        self.assertEqual(collection["status"], "scratch_unavailable")
        # The selectors were never gathered, so the coverage is unknown - not "complete".
        # The key is present whatever the status, so a consumer never has to guess.
        self.assertEqual(collection["selector_coverage"], "unknown")

    # ---- bounds are published, never silent ------------------------------------------
    def test_selector_cap_is_reported_not_applied_silently(self):
        # Ten cluster ids, a cap of eight. An id that was never queried must not be
        # indistinguishable from one that emitted no events.
        self.selectors(*CLUSTER_IDS, handoff="ocm-fvt-cluster-ids")
        result = self.run_step()
        self.assertEqual(result.returncode, 0, result.stderr)
        self.assertIn("querying the first 8", result.stdout)
        collection = self.report()["collection"]
        self.assertEqual(collection["selector_coverage"], "truncated")
        self.assertEqual(collection["status"], "truncated")

    def test_full_selector_coverage_is_reported_too(self):
        self.selectors(*CLUSTER_IDS[:3])
        result = self.run_step()
        self.assertEqual(result.returncode, 0, result.stderr)
        collection = self.report()["collection"]
        self.assertEqual(collection["selector_coverage"], "complete")
        self.assertEqual(collection["status"], "no_events_in_window")

    def test_query_budget_is_bounded_by_the_step_timeout(self):
        # Each query may take two minutes and there can be nine of them, against a ten
        # minute step timeout. A step killed on its timeout writes no report at all, so the
        # queries that no longer fit are skipped and the loss is reported instead.
        self.stub("date", CLOCK_STUB.format(real=shutil.which("date")))
        self.selectors(*CLUSTER_IDS[:6])
        result = self.run_step(CLOCK_FILE=str(self.work / "ticks"), STEP_SECONDS="150")
        self.assertEqual(result.returncode, 0, result.stderr)
        self.assertIn("query budget exhausted", result.stdout)
        self.assertEqual(self.report()["collection"]["status"], "partial")

    def test_empty_response_body_is_treated_as_a_failed_query(self):
        # curl is satisfied by a 204, or by a 200 a proxy emptied. The parser sees no
        # document, has nothing to count, and the artifact would otherwise be identical to
        # a genuine clean collection that found no events.
        self.selectors(CLUSTER_IDS[0])
        result = self.run_step(response_body="")
        self.assertEqual(result.returncode, 0, result.stderr)
        self.assertIn("empty Classic query response", result.stdout)
        self.assertEqual(self.report()["collection"]["status"], "query_failed")

    def test_one_empty_response_among_several_is_still_reported(self):
        self.selectors(*CLUSTER_IDS[:2])
        self.stub("curl", CURL_STUB_EMPTY_FIRST)
        result = self.run_step()
        self.assertEqual(result.returncode, 0, result.stderr)
        self.assertEqual(self.report()["collection"]["status"], "partial")

    def test_no_selector_still_reports_a_status(self):
        result = self.run_step()
        self.assertEqual(result.returncode, 0, result.stderr)
        self.assertEqual(self.report()["collection"]["status"], "selector_unavailable")


class PhaseWindowCase(unittest.TestCase):
    """Runs the phase-window publication block of the FVT step on its own."""

    BANNER = "# Publish the Classic IDP phase windows"
    CAP = 64

    @classmethod
    def setUpClass(cls):
        _require("bash")
        if not FVT.is_file():
            raise unittest.SkipTest(f"{FVT} is not in this checkout")
        body = FVT.read_text()
        start = body.find(cls.BANNER)
        if start < 0:
            raise AssertionError(f"{cls.BANNER!r} not found in {FVT}")
        end = body.find("\nfi\n", start)
        if end < 0:
            raise AssertionError(f"no end of block after {cls.BANNER!r} in {FVT}")
        cls.block = body[start:end + len("\nfi\n")]

    def test_the_cap_keeps_the_newest_windows(self):
        # The lines begin with the phase name, so ordering them whole lets one phase crowd
        # out every window of a later-sorting one - and the parser then tags that phase's
        # events outside_known_phase.
        work = Path(tempfile.mkdtemp())
        self.addCleanup(shutil.rmtree, work, True)
        shared, output = work / "shared", work / "output" / "phase"
        shared.mkdir()
        output.mkdir(parents=True)
        older = [f"htpasswd_user_import 2026-11-11T07:{m:02d}:00.000000Z "
                 f"2026-11-11T07:{m:02d}:01.000000Z" for m in range(self.CAP)]
        newest = [f"idp_delete 2026-11-11T09:{m:02d}:00.000000Z "
                  f"2026-11-11T09:{m:02d}:01.000000Z" for m in range(6)]
        (output / "classic-idp-phase-windows").write_text(
            "".join(line + "\n" for line in older + newest))

        runner = work / "block.sh"
        runner.write_text(f'ocm_fvt_output="{work / "output"}"\n' + self.block)
        result = subprocess.run(["bash", str(runner)], capture_output=True, text=True,
                                env={**os.environ, "SHARED_DIR": str(shared)}, check=False)
        self.assertEqual(result.returncode, 0, result.stderr)

        published = (shared / "classic-idp-phase-windows").read_text().splitlines()
        self.assertLessEqual(len(published), self.CAP)
        self.assertEqual([line for line in published if line in newest], newest,
                         "the cap discarded the newest windows")
        self.assertIn("keeping the newest", result.stdout)


if __name__ == "__main__":
    unittest.main()
