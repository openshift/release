#!/usr/bin/env python3
"""Regression tests for the Classic IDP resync parser shipped inside the
rosa-e2e-collect-cs-telemetry step.

The parser has to live inline in the step's commands script, because ci-operator runs that
script on its own and does not mount this repository. So rather than testing a copy, these
tests extract the parser from the shipped script and run it exactly as the step does. A change
to the script that breaks the contract fails here.

Run with:
    python3 -m unittest discover -s hack/classic-idp-telemetry -p '*_test.py'
"""

import json
import re
import subprocess
import sys
import tempfile
import unittest
from datetime import datetime, timezone
from pathlib import Path

# The helpers below take one keyword per event field on purpose: a test that builds an event
# positionally would stop being readable the moment the schema grows.
# pylint: disable=too-many-arguments,too-many-positional-arguments

REPO = Path(__file__).resolve().parents[2]
STEP = (REPO / "ci-operator/step-registry/rosa/e2e/collect-cs-telemetry"
        / "rosa-e2e-collect-cs-telemetry-commands.sh")

# Identifies the parser block inside the step script, so adding another heredoc cannot
# silently retarget this suite at the wrong one.
PARSER_SENTINEL = "classic-idp-resync-parser"
TAG = "[ROSA CLASSIC IDP]"
SCHEMA = "rosa.classic.idp.resync/v1"
CLUSTER = "2abcdefghijklmnopqrstuvwxyz0123"
# Values that must never survive into the artifact.
SENTINELS = [CLUSTER, "sentinel-user", "sentinel-password", "$2a$10$abcdef",
             "htpasswd-secret-idp", "openshift-config", "connection refused reading secret"]

IN_WINDOW = "2026-11-11T07:10:39.500000Z"
LATER = "2026-11-11T07:10:41.500000Z"
INVOCATION = "2026-11-11T07:10:39.000000Z"
OUT_OF_WINDOW = "2020-01-01T00:00:00.000000Z"


def _epoch(stamp):
    return int(datetime.strptime(stamp, "%Y-%m-%dT%H:%M:%S.%fZ")
               .replace(tzinfo=timezone.utc).timestamp())


# Derived, so the window always brackets the in-window stamps and excludes the other.
START, END = _epoch(IN_WINDOW) - 600, _epoch(LATER) + 600


def extract_parser(destination):
    """Pull the event parser out of the shipped step script."""
    body = STEP.read_text()
    blocks = [b for b in re.findall(r"<<'PYEOF'\n(.*?)\nPYEOF", body, re.S)
              if PARSER_SENTINEL in b]
    if len(blocks) != 1:
        raise AssertionError(
            f"expected exactly one block containing {PARSER_SENTINEL!r} in {STEP}, "
            f"found {len(blocks)}")
    path = destination / "parser.py"
    path.write_text(blocks[-1])
    return path


def event(op="lease_delete", outcome="deleted", time=IN_WINDOW, build="0f1e2d3",
          schema=SCHEMA, generation=None, attempt=1, flow="secret_mapping",
          toggle="unavailable", toggle_reason="not_present_in_build",
          invocation=INVOCATION, extra=None, drop=()):
    payload = {"schema": schema, "op": op, "outcome": outcome, "flow": flow,
               "toggle": toggle, "toggle_reason": toggle_reason, "build": build,
               "invocation": invocation, "time": time, "attempt": attempt}
    if generation is not None:
        payload["generation"] = generation
    for key in drop:
        payload.pop(key, None)
    if extra:
        payload.update(extra)
    return TAG + " " + json.dumps(payload)


def encoder_line(message, trailing=True):
    """A line shaped like the service's log encoder writes it: bracketed context fields
    before the message and configured fields after it."""
    prefix = f"2026-11-11T07:10:39.500Z INFO [opid='op-1'] [cid='{CLUSTER}'] "
    return prefix + message + (" user=sentinel-user@example.com" if trailing else "")


class ParserCase(unittest.TestCase):  # pylint: disable=too-many-public-methods
    @classmethod
    def setUpClass(cls):
        # Kept open for the lifetime of the class and released in tearDownClass; a with
        # block cannot span setUpClass/tearDownClass.
        cls._work = tempfile.TemporaryDirectory()  # pylint: disable=consider-using-with
        cls.parser = extract_parser(Path(cls._work.name))

    @classmethod
    def tearDownClass(cls):
        cls._work.cleanup()

    def run_parser(self, lines, phases=(), query_ok="true", truncated="false",
                   documents=None, start=START, end=END):
        """Run the shipped parser over Loki documents and return (report, raw text)."""
        work = Path(tempfile.mkdtemp(dir=self._work.name))
        merged, phase_file, out = work / "merged.json", work / "phases", work / "report.json"
        if documents is None:
            documents = [{"data": {"result": [{"values": [["0", line] for line in lines]}]}}]
        merged.write_text("\n".join(json.dumps(d) for d in documents))
        phase_file.write_text("".join(f"{n} {a} {b}\n" for n, a, b in phases))
        result = subprocess.run(
            [sys.executable, "-I", str(self.parser), str(merged), str(phase_file), str(out),
             str(start), str(end), query_ok, truncated],
            capture_output=True, text=True, check=False)
        self.assertEqual(result.returncode, 0, result.stderr)
        text = out.read_text()
        return json.loads(text), text

    # ---- happy path -----------------------------------------------------------------
    def test_all_four_writes_survive_realistic_encoder_lines(self):
        report, text = self.run_parser([
            encoder_line(event("source_secret_write", "succeeded", generation=None)),
            encoder_line(event("lease_delete", "deleted"), trailing=False),
            encoder_line(event("sync_identity_provider_write", "succeeded", generation=5)),
            encoder_line(event("syncset_write", "succeeded", time=LATER, generation=5)),
        ])
        self.assertEqual(report["collection"]["status"], "collected")
        self.assertEqual(len(report["events"]), 4, report["rejected"])
        self.assertEqual(sum(report["rejected"].values()), 0, report["rejected"])
        self.assertEqual({e["op"] for e in report["events"]},
                         {"source_secret_write", "lease_delete",
                          "sync_identity_provider_write", "syncset_write"})
        for sentinel in SENTINELS:
            self.assertNotIn(sentinel, text)
        self.assertNotIn("cluster_id", text)
        self.assertNotIn("opid", text)
        self.assertNotIn("user=", text)

    def test_envelope_is_stripped_whole(self):
        for key in ("message", "msg", "log", "_line"):
            envelope = {key: encoder_line(event()), "level": "info", "cid": CLUSTER,
                        "kubernetes": {"pod_name": "sentinel-user"}}
            report, text = self.run_parser([json.dumps(envelope)])
            self.assertEqual(len(report["events"]), 1, (key, report["rejected"]))
            for sentinel in SENTINELS:
                self.assertNotIn(sentinel, text)
            self.assertNotIn("pod_name", text)

    def test_unknown_envelope_key_is_rejected_not_leaked(self):
        report, text = self.run_parser([json.dumps({"unknown_key": encoder_line(event())})])
        self.assertEqual(report["events"], [])
        self.assertEqual(report["rejected"]["unwrap_failed"], 1)
        for sentinel in SENTINELS:
            self.assertNotIn(sentinel, text)

    # ---- rejection paths ------------------------------------------------------------
    def test_rejection_paths(self):
        cases = [
            ("unknown_op", event(op="delete_everything")),
            ("unknown_outcome", event(outcome="sentinel-outcome")),
            ("unknown_schema", event(schema=SCHEMA + "9")),
            ("unknown_flow", event(flow="legacy_embedded")),
            ("unknown_toggle", event(toggle="disabled")),
            ("unknown_toggle", event(toggle_reason="operator_turned_it_off")),
            ("unexpected_field", event(extra={"error": "connection refused reading secret"})),
            ("unexpected_field", event(extra={"cluster_id": CLUSTER})),
            ("undecodable_payload", TAG + " not-json"),
            ("unwrap_failed", "[ROSA HCP - IT1] Cluster: 'sentinel-user'"),
            ("out_of_window", event(time=OUT_OF_WINDOW)),
            ("invalid_time", event(time="11 Nov 2026")),
            ("invalid_time", event(invocation="nope")),
            ("invalid_generation", event(generation=-1)),
            ("invalid_generation", event(generation=True)),
            ("invalid_attempt", event(attempt=0)),
            ("invalid_attempt", event(attempt=True)),
            ("invalid_attempt", event(drop=("attempt",))),
            ("oversize_line", TAG + " " + "x" * 20000),
        ]
        for bucket, line in cases:
            with self.subTest(bucket=bucket, line=line[:60]):
                report, text = self.run_parser([line])
                self.assertEqual(report["events"], [], bucket)
                self.assertEqual(report["rejected"][bucket], 1, report["rejected"])
                for sentinel in SENTINELS:
                    self.assertNotIn(sentinel, text)

    # ---- build shape ----------------------------------------------------------------
    def test_build_shape_does_not_claim_git_provenance(self):
        for build, shape, emitted in [
            ("0f1e2d3", "git_object_name", True),
            ("0f1e2d3c4b5a6978899a0b1c2d3e4f5061728394", "git_object_name", True),
            ("1762848000", "ambiguous_numeric_or_git_object_name", True),
            ("abc", "unrecognized", False),
            ("not-a-sha", "unrecognized", False),
            ("0F1E2D3", "unrecognized", False),
        ]:
            with self.subTest(build=build):
                report, _ = self.run_parser([event(build=build)])
                got = report["events"][0]
                self.assertEqual(got["build_shape"], shape)
                self.assertEqual("build" in got, emitted)
                if not emitted:
                    self.assertEqual(report["anomalies"]["build_not_recorded"], 1)
                    # Withholding a build does not drop the event.
                    self.assertEqual(sum(report["rejected"].values()), 0)

    # ---- phase correlation ----------------------------------------------------------
    def test_phase_windows_attribute_an_event(self):
        phases = [("htpasswd_user_import", "2026-11-11T07:10:39.000000Z",
                   "2026-11-11T07:10:40.000000Z")]
        report, _ = self.run_parser([event(time=IN_WINDOW), event(time=LATER)], phases=phases)
        self.assertEqual(report["collection"]["phase_windows"], "present")
        phases_seen = sorted(e["test_phase"] for e in report["events"])
        self.assertEqual(phases_seen, ["htpasswd_user_import", "outside_known_phase"])

    def test_absent_phase_windows_are_reported_not_guessed(self):
        report, _ = self.run_parser([event()])
        self.assertEqual(report["collection"]["phase_windows"], "unavailable")
        self.assertEqual(report["events"][0]["test_phase"], "phase_unavailable")

    def test_phase_name_outside_the_closed_set_is_not_published(self):
        # SHARED_DIR is writable by every step in the job, so a name the suite would never
        # record must not be echoed into the artifact.
        phases = [("sentinel_phase", "2026-11-11T07:10:39.000000Z",
                   "2026-11-11T07:10:40.000000Z")]
        report, text = self.run_parser([event()], phases=phases)
        self.assertNotIn("sentinel_phase", text)
        self.assertEqual(report["collection"]["phase_windows"], "unavailable")
        self.assertEqual(report["events"][0]["test_phase"], "phase_unavailable")

    def test_nested_windows_resolve_to_the_narrowest(self):
        phases = [("idp_create", "2026-11-11T07:10:00.000000Z",
                   "2026-11-11T07:11:00.000000Z"),
                  ("htpasswd_user_import", "2026-11-11T07:10:30.000000Z",
                   "2026-11-11T07:10:50.000000Z")]
        report, _ = self.run_parser([event(time=IN_WINDOW)], phases=phases)
        self.assertEqual(report["events"][0]["test_phase"], "htpasswd_user_import")

    def test_one_malformed_document_does_not_discard_the_others(self):
        good = {"data": {"result": [{"values": [["0", event()]]}]}}
        work = Path(tempfile.mkdtemp(dir=self._work.name))
        merged, phase_file, out = work / "merged.json", work / "phases", work / "report.json"
        # A 200 with a non-JSON body for one selector, between two good responses.
        merged.write_text(json.dumps(good) + "\nnot json at all\n" + json.dumps(good))
        phase_file.write_text("")
        result = subprocess.run(
            [sys.executable, "-I", str(self.parser), str(merged), str(phase_file), str(out),
             str(START), str(END), "true", "false"], capture_output=True, text=True,
            check=False)
        self.assertEqual(result.returncode, 0, result.stderr)
        report = json.loads(out.read_text())
        # Both good documents survive - they are separate selector groups, so their events
        # stay distinguishable - and the loss is reported rather than presented as a clean
        # collection.
        self.assertEqual(len(report["events"]), 2, report)
        self.assertEqual({e["cluster_group"] for e in report["events"]}, {0, 1})
        self.assertEqual(report["rejected"]["malformed_document"], 1)
        self.assertEqual(report["collection"]["status"], "partial")

    def test_malformed_phase_lines_are_skipped(self):
        phases = [("not a phase name!", IN_WINDOW, LATER),
                  ("htpasswd_user_import", "bogus", LATER)]
        report, _ = self.run_parser([event()], phases=phases)
        self.assertEqual(report["collection"]["phase_windows"], "unavailable")

    # ---- correlation ----------------------------------------------------------------
    def test_two_invocations_do_not_collapse(self):
        other = "2026-11-11T07:10:41.000000Z"
        report, _ = self.run_parser([
            event(op="syncset_write", outcome="conflict", attempt=1, invocation=INVOCATION),
            event(op="syncset_write", outcome="succeeded", attempt=1, invocation=other,
                  time=LATER),
        ])
        self.assertEqual(len(report["events"]), 2)
        self.assertEqual(len({e["invocation"] for e in report["events"]}), 2)

    def test_retries_within_one_invocation_are_ordered(self):
        report, _ = self.run_parser([
            event(op="syncset_write", outcome="succeeded", attempt=2, time=LATER),
            event(op="syncset_write", outcome="conflict", attempt=1, time=IN_WINDOW),
        ])
        self.assertEqual([e["attempt"] for e in report["events"]], [1, 2])

    def test_duplicate_lines_within_one_response_are_collapsed(self):
        line = event()
        report, _ = self.run_parser([line, line])
        self.assertEqual(len(report["events"]), 1)

    def test_separate_selector_groups_stay_distinguishable(self):
        # Each query filters on one cluster id, so a line belongs to exactly one group. Two
        # groups must not be merged, or a write against another cluster would be read as
        # part of this one - and the group ordinal is a position, never an identifier.
        line = event()
        report, text = self.run_parser(
            [], documents=[{"data": {"result": [{"values": [["0", line]]}]}},
                           {"data": {"result": [{"values": [["0", line]]}]}}])
        self.assertEqual(len(report["events"]), 2)
        self.assertEqual({e["cluster_group"] for e in report["events"]}, {0, 1})
        for sentinel in SENTINELS:
            self.assertNotIn(sentinel, text)

    def test_single_group_omits_the_group_ordinal(self):
        report, _ = self.run_parser([event()])
        self.assertNotIn("cluster_group", report["events"][0])

    def test_attempt_event_is_collected_and_claims_no_flow(self):
        report, _ = self.run_parser([event(op="resync_attempt", outcome="started",
                                           flow="not_yet_selected")])
        self.assertEqual(len(report["events"]), 1, report["rejected"])
        self.assertEqual(report["events"][0]["op"], "resync_attempt")
        self.assertEqual(report["events"][0]["flow"], "not_yet_selected")

    # ---- collection status ----------------------------------------------------------
    def test_status_distinguishes_empty_partial_and_truncated(self):
        self.assertEqual(self.run_parser([])[0]["collection"]["status"],
                         "no_events_in_window")
        self.assertEqual(self.run_parser([event()], query_ok="false")[0]["collection"]["status"],
                         "partial")
        # Truncation must never be presented as a clean empty result.
        truncated = self.run_parser([], truncated="true")[0]
        self.assertEqual(truncated["collection"]["status"], "truncated")
        self.assertEqual(truncated["events"], [])

    # ---- malformed inputs -----------------------------------------------------------
    def test_malformed_documents_do_not_crash_the_step(self):
        for document in ([], {"data": None}, {"data": {"result": [None]}},
                         {"data": {"result": [{"values": [["only-one"], [], ["0", 1], ["0", None]]}]}}):
            with self.subTest(document=str(document)[:40]):
                report, _ = self.run_parser([], documents=[document])
                self.assertEqual(report["events"], [])

    def test_unreadable_merged_file_is_not_fatal(self):
        work = Path(tempfile.mkdtemp(dir=self._work.name))
        out = work / "report.json"
        (work / "phases").write_text("")
        result = subprocess.run(
            [sys.executable, "-I", str(self.parser), str(work / "absent.json"),
             str(work / "phases"), str(out), str(START), str(END), "true", "false"],
            capture_output=True, text=True, check=False)
        self.assertEqual(result.returncode, 0, result.stderr)
        self.assertEqual(json.loads(out.read_text())["events"], [])

    # ---- artifact field allowlist ---------------------------------------------------
    def test_artifact_fields_are_allowlisted(self):
        report, _ = self.run_parser([event(generation=5)])
        allowed = {"op", "outcome", "flow", "toggle", "toggle_reason", "invocation", "time",
                   "attempt", "test_phase", "build_shape", "build", "generation"}
        for recorded in report["events"]:
            self.assertLessEqual(set(recorded), allowed)
        self.assertEqual(set(report), {"schema", "window", "collection", "events",
                                       "rejected", "anomalies"})


if __name__ == "__main__":
    unittest.main()
