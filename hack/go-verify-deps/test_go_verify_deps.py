#!/usr/bin/env python3
"""Unit tests for the go-verify-deps Python step.

The step's commands file lives in the step registry and is named with a hyphen
(go-verify-deps-commands.py), which is not a legal Python module name and cannot
live next to tests in the registry dir (the loader forbids it). So we import the
real file BY PATH via importlib — single source of truth, no code duplication.

Standard library only (unittest); run with:
    python3 -m unittest discover -s hack/go-verify-deps -p 'test_*.py' -v
"""

import contextlib
import importlib.util
import io
import os
import shutil
import sys
import tempfile
import time
import types
import unittest

_HERE = os.path.dirname(os.path.abspath(__file__))
_REPO = os.path.abspath(os.path.join(_HERE, "..", ".."))
_MOD_PATH = os.path.join(
    _REPO, "ci-operator", "step-registry", "go", "verify-deps",
    "go-verify-deps-commands.py",
)


def _load_module():
    name = "go_verify_deps_commands"
    spec = importlib.util.spec_from_file_location(name, _MOD_PATH)
    module = importlib.util.module_from_spec(spec)
    # Register before exec so the module's `from __future__ import annotations`
    # dataclasses can resolve their string annotations via sys.modules.
    sys.modules[name] = module
    spec.loader.exec_module(module)
    return module


mod = _load_module()


def _cand(spec):
    """Build a commands.Candidate from a 'path@version' spec string."""
    path, version = spec.split("@", 1)
    return mod.Candidate(path, version)


class PureFunctionTests(unittest.TestCase):
    """Functions with no external dependencies."""

    def test_goproxy_escape(self):
        self.assertEqual(mod.goproxy_escape("github.com/Azure/foo"),
                         "github.com/!azure/foo")
        self.assertEqual(mod.goproxy_escape("github.com/openshift/api"),
                         "github.com/openshift/api")
        self.assertEqual(mod.goproxy_escape("ABC"), "!a!b!c")

    def test_redact_strips_userinfo(self):
        got = mod.goproxy_redact_url(
            "https://user:s3cr3t@proxy.example.test/github.com/x/@v/v1.info")
        self.assertEqual(
            got, "https://proxy.example.test/github.com/x/@v/v1.info")
        self.assertNotIn("s3cr3t", got)

    def test_redact_strips_query_and_fragment(self):
        self.assertEqual(
            mod.goproxy_redact_url("https://p.test/x?token=abc#frag"),
            "https://p.test/x")

    def test_redact_leaves_clean_url_and_proxy_path_at_sign(self):
        # The "/@v/" segment must survive (its '@' follows a '/').
        url = "https://proxy.golang.org/github.com/foo/@v/v0.0.0-x.info"
        self.assertEqual(mod.goproxy_redact_url(url), url)

    def test_redact_strips_multi_at_password(self):
        # A password containing '@' must be fully stripped (everything up to the
        # LAST '@' in the authority), and a '/@v/' path segment preserved.
        got = mod.goproxy_redact_url(
            "https://user:p@ss@w0rd@host/github.com/x/@v/v1.info?t=1#f")
        self.assertEqual(got, "https://host/github.com/x/@v/v1.info")
        for secret in ("p@ss", "w0rd", "user", "t=1", "#f"):
            self.assertNotIn(secret, got)

    def test_private_match_exact_and_prefix(self):
        pats = ["github.com/example/benign"]
        self.assertTrue(mod.goproxy_path_is_private(
            "github.com/example/benign", pats))
        self.assertTrue(mod.goproxy_path_is_private(
            "github.com/example/benign/sub", pats))
        self.assertFalse(mod.goproxy_path_is_private(
            "github.com/example/other", pats))

    def test_private_no_false_positive_on_suffix(self):
        # installer-aro must NOT match a pattern for installer.
        self.assertFalse(mod.goproxy_path_is_private(
            "github.com/openshift/installer-aro",
            ["github.com/openshift/installer"]))

    def test_private_glob(self):
        pats = ["github.com/corp/*"]
        self.assertTrue(mod.goproxy_path_is_private("github.com/corp/x", pats))
        self.assertTrue(mod.goproxy_path_is_private("github.com/corp/x/y", pats))
        self.assertFalse(mod.goproxy_path_is_private("github.com/other/x", pats))

    def test_private_pathmatch_bracket_and_question(self):
        # Go path.Match element-wise semantics: '[...]' classes and '?'.
        self.assertTrue(mod.goproxy_path_is_private(
            "github.com/corp/alpha", ["github.com/corp/[ab]*"]))
        self.assertTrue(mod.goproxy_path_is_private(
            "github.com/corp/bar", ["github.com/corp/ba?"]))
        # non-matching class
        self.assertFalse(mod.goproxy_path_is_private(
            "github.com/corp/alpha", ["github.com/corp/[xy]*"]))
        # '*' must not cross a '/' element boundary at the same depth
        self.assertFalse(mod.goproxy_path_is_private(
            "github.com/corp", ["github.com/corp/*"]))

    def test_pseudo_version_regex(self):
        match = [
            "v0.0.0-20261110024958-4608138db381",
            "v1.37.0-alpha.0.0.20261110024958-4608138db381",  # dot-separated
            "v1.2.4-0.20240101000000-abcdef123456",
            "v1.2.3-20240101000000-abcdef123456+incompatible",
        ]
        nomatch = ["v1.11.1", "v2.1.0+incompatible", "v1.4.22-ec5"]
        for v in match:
            self.assertTrue(mod.PSEUDO_RE.search(v), f"should match: {v}")
        for v in nomatch:
            self.assertFalse(mod.PSEUDO_RE.search(v), f"should NOT match: {v}")

    def test_candidates_replace_aware(self):
        data = {
            "Require": [
                {"Path": "github.com/foo/foo",
                 "Version": "v0.0.0-20240101000000-aaaaaaaaaaaa"},
                {"Path": "github.com/keep/keep",
                 "Version": "v0.0.0-20240101000000-cccccccccccc"},
                {"Path": "github.com/drop/drop",
                 "Version": "v0.0.0-20240101000000-dddddddddddd"},
            ],
            "Replace": [
                # remote replace: original require dropped, target probed
                {"Old": {"Path": "github.com/foo/foo"},
                 "New": {"Path": "github.com/bar/bar",
                         "Version": "v0.0.0-20240101000000-bbbbbbbbbbbb"}},
                # local-path replace: module dropped entirely
                {"Old": {"Path": "github.com/drop/drop"},
                 "New": {"Path": "./vendored", "Version": ""}},
            ],
        }
        out = mod.candidates_from_json(data)
        specs = [c.spec for c in out]
        self.assertIn("github.com/bar/bar@v0.0.0-20240101000000-bbbbbbbbbbbb", specs)
        self.assertIn("github.com/keep/keep@v0.0.0-20240101000000-cccccccccccc", specs)
        # original require of a replaced module is NOT emitted
        self.assertNotIn(
            "github.com/foo/foo@v0.0.0-20240101000000-aaaaaaaaaaaa", specs)
        # local-path replaced module is dropped entirely
        for c in out:
            self.assertFalse(c.path.startswith("github.com/drop/drop"))
            self.assertFalse(c.path.startswith("./"))
        # sorted + unique by spec (matches `sort -u`)
        self.assertEqual(specs, sorted(set(specs)))

    def test_candidates_version_specific_replace(self):
        # A replace with an explicit Old.Version only suppresses THAT version; a
        # differently-versioned required pin survives.
        data = {
            "Require": [
                {"Path": "github.com/foo/foo",
                 "Version": "v0.0.0-20240101000000-222222222222"},  # different version
            ],
            "Replace": [
                {"Old": {"Path": "github.com/foo/foo",
                         "Version": "v0.0.0-20240101000000-111111111111"},
                 "New": {"Path": "github.com/bar/bar",
                         "Version": "v0.0.0-20240101000000-bbbbbbbbbbbb"}},
            ],
        }
        specs = [c.spec for c in mod.candidates_from_json(data)]
        self.assertIn("github.com/foo/foo@v0.0.0-20240101000000-222222222222", specs)
        self.assertIn("github.com/bar/bar@v0.0.0-20240101000000-bbbbbbbbbbbb", specs)

    def test_candidates_wildcard_vs_versioned_vs_local(self):
        data = {
            "Require": [
                {"Path": "github.com/wild/wild",
                 "Version": "v0.0.0-20240101000000-333333333333"},
                {"Path": "github.com/ver/ver",
                 "Version": "v0.0.0-20240101000000-444444444444"},
                {"Path": "github.com/loc/loc",
                 "Version": "v0.0.0-20240101000000-555555555555"},
            ],
            "Replace": [
                # wildcard replace -> drops all versions of wild
                {"Old": {"Path": "github.com/wild/wild"},
                 "New": {"Path": "github.com/newwild/newwild",
                         "Version": "v0.0.0-20240101000000-666666666666"}},
                # version-specific replace that MATCHES the required version -> dropped
                {"Old": {"Path": "github.com/ver/ver",
                         "Version": "v0.0.0-20240101000000-444444444444"},
                 "New": {"Path": "github.com/newver/newver",
                         "Version": "v0.0.0-20240101000000-777777777777"}},
                # local replace -> dropped, nothing emitted
                {"Old": {"Path": "github.com/loc/loc"},
                 "New": {"Path": "../local", "Version": ""}},
            ],
        }
        specs = [c.spec for c in mod.candidates_from_json(data)]
        # wildcard-replaced require dropped; its remote target emitted
        self.assertNotIn("github.com/wild/wild@v0.0.0-20240101000000-333333333333", specs)
        self.assertIn("github.com/newwild/newwild@v0.0.0-20240101000000-666666666666", specs)
        # version-matched require dropped; its remote target emitted
        self.assertNotIn("github.com/ver/ver@v0.0.0-20240101000000-444444444444", specs)
        self.assertIn("github.com/newver/newver@v0.0.0-20240101000000-777777777777", specs)
        # local replace drops the require and emits nothing
        self.assertNotIn("github.com/loc/loc@v0.0.0-20240101000000-555555555555", specs)
        self.assertTrue(all(not s.startswith("../") for s in specs))

    def test_external_probe_cmd_timeout(self):
        # A stalled GOPROXY_PROBE_CMD is killed by the subprocess timeout and
        # treated as a transport failure (000).
        start = time.monotonic()
        code = mod.probe_cmd("/bin/sleep", "30", timeout=0.5)
        elapsed = time.monotonic() - start
        self.assertEqual(code, "000")
        self.assertLess(elapsed, 5)

    def test_report_missing_formatting(self):
        rec = mod.ProbeRecord(
            path="github.com/openshift/kubernetes",
            version="v1.37.0-alpha.0.0.20261110024958-4608138db381",
            commit="4608138db381",
            url="https://proxy.example.test/github.com/openshift/kubernetes/@v/"
                "v1.37.0-alpha.0.0.20261110024958-4608138db381.info",
            status="404",
        )
        buf = io.StringIO()
        with contextlib.redirect_stdout(buf):
            mod.goproxy_report_missing("https://proxy.example.test", [rec])
        out = buf.getvalue()
        self.assertIn("Unresolvable module pseudo-version(s):", out)
        self.assertIn("module:  github.com/openshift/kubernetes", out)
        self.assertIn(
            "version: v1.37.0-alpha.0.0.20261110024958-4608138db381", out)
        self.assertIn("Go module proxy base URL (redacted): https://proxy.example.test", out)
        self.assertIn("go get", out)
        self.assertIn("tag", out)


class CheckAvailabilityTests(unittest.TestCase):  # pylint: disable=too-many-instance-attributes  # a test fixture saving/restoring several module globals
    """Exercise check_goproxy_availability() with an injected fake prober.

    enumerate_candidates and go_env are monkeypatched so the tests are hermetic
    (no dependency on the `go` binary or the network)."""

    def setUp(self):
        self._env = dict(os.environ)
        self._cwd = os.getcwd()
        self._orig_enum = mod.enumerate_candidates
        self._orig_goenv = mod.go_env
        self._orig_probe = mod.PROBE_OVERRIDE
        self._orig_time = mod.time
        # Retry/backoff/deadline are module constants now (no longer env tunables);
        # save and set small, instant values, and restore in tearDown.
        self._orig_retries = mod.GOPROXY_RETRIES
        self._orig_delay = mod.GOPROXY_RETRY_DELAY_SECONDS
        self._orig_deadline = mod.GOPROXY_DEADLINE_SECONDS
        self._orig_rng_state = mod.JITTER_RNG.getstate()
        self._tmp = tempfile.mkdtemp()
        os.chdir(self._tmp)
        # check_goproxy_availability() returns early unless go.mod exists.
        with open(os.path.join(self._tmp, "go.mod"), "w", encoding="utf-8") as fh:
            fh.write("module example.com/t\n\ngo 1.22.0\n")
        os.environ["CHECK_GOPROXY_AVAILABILITY"] = "true"
        # Undeclared test-only hook: point the probe at a fake proxy base URL.
        os.environ["GOPROXY_AVAILABILITY_URL"] = "https://proxy.example.test"
        os.environ.pop("GONOPROXY", None)
        os.environ.pop("GOPRIVATE", None)
        mod.GOPROXY_RETRIES = 1
        mod.GOPROXY_RETRY_DELAY_SECONDS = 0
        mod.GOPROXY_DEADLINE_SECONDS = 120
        # Hermetic: no real `go env` calls.
        mod.go_env = lambda name: ""

    def tearDown(self):
        os.environ.clear()
        os.environ.update(self._env)
        os.chdir(self._cwd)
        shutil.rmtree(self._tmp, ignore_errors=True)
        mod.enumerate_candidates = self._orig_enum
        mod.go_env = self._orig_goenv
        mod.PROBE_OVERRIDE = self._orig_probe
        mod.time = self._orig_time
        mod.GOPROXY_RETRIES = self._orig_retries
        mod.GOPROXY_RETRY_DELAY_SECONDS = self._orig_delay
        mod.GOPROXY_DEADLINE_SECONDS = self._orig_deadline
        mod.JITTER_RNG.setstate(self._orig_rng_state)

    def _run_check(self):
        buf = io.StringIO()
        rc = 0
        try:
            with contextlib.redirect_stdout(buf), contextlib.redirect_stderr(buf):
                mod.check_goproxy_availability()
        except SystemExit as exc:
            rc = exc.code if isinstance(exc.code, int) else 1
        return buf.getvalue(), rc

    def test_unset_env_disables_check(self):
        # Opt-in default-off: an unset master switch must NOT probe (B1 parity
        # with the ref default "false").
        os.environ.pop("CHECK_GOPROXY_AVAILABILITY", None)
        called = {"n": 0}

        def prober(_url):
            called["n"] += 1
            return "404"

        mod.PROBE_OVERRIDE = prober
        mod.enumerate_candidates = lambda: [
            _cand("github.com/x/x@v0.0.0-20240101000000-abcdef123456")]
        out, rc = self._run_check()
        self.assertEqual(rc, 0, out)
        self.assertEqual(called["n"], 0, "prober must not run when switch is unset")
        self.assertEqual(out.strip(), "", "no output when the check is disabled")

    def test_explicit_false_disables_check(self):
        os.environ["CHECK_GOPROXY_AVAILABILITY"] = "false"
        called = {"n": 0}

        def prober(_url):
            called["n"] += 1
            return "404"

        mod.PROBE_OVERRIDE = prober
        mod.enumerate_candidates = lambda: [
            _cand("github.com/x/x@v0.0.0-20240101000000-abcdef123456")]
        out, rc = self._run_check()
        self.assertEqual(rc, 0, out)
        self.assertEqual(called["n"], 0)

    def test_retry_then_available(self):
        calls = {"n": 0}

        def prober(_url):
            calls["n"] += 1
            return "200" if calls["n"] >= 2 else "000"

        mod.enumerate_candidates = lambda: [
            _cand("github.com/x/x@v0.0.0-20240101000000-abcdef123456")]
        mod.PROBE_OVERRIDE = prober
        mod.GOPROXY_RETRIES = 3
        out, rc = self._run_check()
        self.assertEqual(rc, 0, out)
        self.assertIn("OK           github.com/x/x@", out)
        self.assertEqual(calls["n"], 2)  # retried once, succeeded on 2nd

    def test_missing_pin_fails_with_remediation(self):
        mod.enumerate_candidates = lambda: [
            _cand("github.com/openshift/kubernetes@"
                  "v1.37.0-alpha.0.0.20261110024958-4608138db381")]
        mod.PROBE_OVERRIDE = lambda _url: "404"
        out, rc = self._run_check()
        self.assertEqual(rc, 1, out)
        self.assertIn("Unresolvable module pseudo-version(s):", out)
        self.assertIn("go get", out)
        self.assertIn("github.com/openshift/kubernetes", out)

    def test_outage_short_circuit(self):
        cands = [
            _cand(f"github.com/{c}/{c}@v0.0.0-20240101000000-{c}00000000000")
            for c in "abcde"
        ]
        mod.enumerate_candidates = lambda: cands
        mod.PROBE_OVERRIDE = lambda _url: "000"  # transport failure
        mod.GOPROXY_RETRIES = 1
        out, rc = self._run_check()
        # Outage short-circuit never fails the check.
        self.assertEqual(rc, 0, out)
        # 3 consecutive 000 then the remaining 2 are skipped as outage.
        self.assertIn("skipped: outage", out)
        self.assertIn(
            "stopped probing 2 module version(s) early (outage)", out)
        # all 5 appear as INCONCLUSIVE (3 probed + 2 skipped)
        self.assertEqual(out.count("INCONCLUSIVE"), 5, out)

    def test_private_module_skipped(self):
        mod.enumerate_candidates = lambda: [
            _cand("github.com/example/benign@v0.0.0-20240229000000-abcdef123456"),
            _cand("github.com/other/pkg@v0.0.0-20240229000000-abcdef123456"),
        ]
        mod.go_env = lambda name: "github.com/example/benign" if name == "GONOPROXY" else ""
        mod.PROBE_OVERRIDE = lambda _url: "200"
        out, rc = self._run_check()
        self.assertEqual(rc, 0, out)
        self.assertIn(
            "Skipping private module(s) matched by GONOPROXY/GOPRIVATE:", out)
        self.assertIn("github.com/example/benign", out)
        # private module must not be probed
        self.assertNotIn("github.com/example/benign@", out)
        # the non-private one is still probed
        self.assertIn("OK           github.com/other/pkg@", out)

    def test_deadline_caps_retry_sleeps(self):
        # Per-retry deadline budget: with a slow/failing prober, each retry sleep
        # is capped to the remaining budget and the total wait is bounded by the
        # deadline. Never a hard fail (INCONCLUSIVE). Uses a fake clock so the
        # test is instant and deterministic.
        clock = [0.0]
        sleeps = []

        def fake_sleep(seconds):
            sleeps.append(seconds)
            clock[0] += seconds

        mod.time = types.SimpleNamespace(monotonic=lambda: clock[0], sleep=fake_sleep)
        mod.JITTER_RNG.seed(0)  # deterministic jitter
        mod.GOPROXY_RETRIES = 5
        mod.GOPROXY_RETRY_DELAY_SECONDS = 10  # would overshoot without the cap
        mod.GOPROXY_DEADLINE_SECONDS = 5
        mod.enumerate_candidates = lambda: [
            _cand("github.com/a/a@v0.0.0-20240101000000-a00000000000"),
            _cand("github.com/b/b@v0.0.0-20240101000000-b00000000000"),
        ]
        mod.PROBE_OVERRIDE = lambda _url: "000"  # always a transport failure
        out, rc = self._run_check()
        self.assertEqual(rc, 0, out)  # deadline/outage never hard-fails
        self.assertTrue(sleeps, "expected at least one retry sleep")
        self.assertTrue(all(s <= 5 for s in sleeps), sleeps)  # each sleep capped
        self.assertLessEqual(sum(sleeps), 5)  # total wait bounded by the deadline
        self.assertIn("INCONCLUSIVE", out)

    def test_retry_after_429_honored(self):
        # A 429 that advertises a Retry-After makes the next backoff wait AT LEAST
        # that many seconds (the small base backoff would otherwise be far shorter).
        # Capped only by the overall deadline, which here has ample headroom.
        clock = [0.0]
        sleeps = []

        def fake_sleep(seconds):
            sleeps.append(seconds)
            clock[0] += seconds

        mod.time = types.SimpleNamespace(monotonic=lambda: clock[0], sleep=fake_sleep)
        mod.JITTER_RNG.seed(0)
        mod.GOPROXY_RETRIES = 2
        mod.GOPROXY_RETRY_DELAY_SECONDS = 1  # base backoff far below the advertised 30s
        mod.GOPROXY_DEADLINE_SECONDS = 120  # headroom so the cap never clips below 30
        mod.enumerate_candidates = lambda: [
            _cand("github.com/x/x@v0.0.0-20240101000000-abcdef123456")]
        # ProbeResponse carries the Retry-After the server would advertise on a 429.
        mod.PROBE_OVERRIDE = lambda _url: mod.ProbeResponse("429", 30.0)
        out, rc = self._run_check()
        self.assertEqual(rc, 0, out)  # 429 is inconclusive, never a hard fail
        self.assertEqual(len(sleeps), 1, sleeps)
        self.assertGreaterEqual(sleeps[0], 30.0)  # waited at least the advertised delay
        self.assertIn("INCONCLUSIVE", out)

    def test_jitter_bounded_and_deterministic(self):
        # Backoff jitter stays within +/-20% of the base delay and is reproducible
        # under a seeded RNG. The deadline is disabled so nothing clips the jitter.
        def run_once():
            clock = [0.0]
            sleeps = []

            def fake_sleep(seconds):
                sleeps.append(seconds)
                clock[0] += seconds

            mod.time = types.SimpleNamespace(monotonic=lambda: clock[0], sleep=fake_sleep)
            mod.JITTER_RNG.seed(1234)
            mod.GOPROXY_RETRIES = 2
            mod.GOPROXY_RETRY_DELAY_SECONDS = 10
            mod.GOPROXY_DEADLINE_SECONDS = 0  # disable the deadline (no capping)
            mod.enumerate_candidates = lambda: [
                _cand("github.com/x/x@v0.0.0-20240101000000-abcdef123456")]
            mod.PROBE_OVERRIDE = lambda _url: "000"
            out, rc = self._run_check()
            self.assertEqual(rc, 0, out)
            return sleeps

        first = run_once()
        second = run_once()
        self.assertEqual(len(first), 1, first)
        self.assertEqual(first, second)  # deterministic under the same seed
        self.assertTrue(8.0 <= first[0] <= 12.0, first)  # base 10 with +/-20% jitter

    def test_per_attempt_timeout_capped_to_budget(self):
        # Each probe attempt's timeout is capped to min(DEFAULT_PROBE_TIMEOUT,
        # remaining budget), so a single attempt cannot overrun the deadline.
        clock = [0.0]
        timeouts = []

        def fake_sleep(seconds):
            clock[0] += seconds

        mod.time = types.SimpleNamespace(monotonic=lambda: clock[0], sleep=fake_sleep)
        mod.JITTER_RNG.seed(0)
        mod.GOPROXY_RETRIES = 5
        mod.GOPROXY_RETRY_DELAY_SECONDS = 1
        mod.GOPROXY_DEADLINE_SECONDS = 5  # smaller than DEFAULT_PROBE_TIMEOUT (15)
        mod.enumerate_candidates = lambda: [
            _cand("github.com/x/x@v0.0.0-20240101000000-abcdef123456")]

        # Two-parameter override: receives and records the per-attempt timeout.
        def prober(_url, timeout):
            timeouts.append(timeout)
            return "000"

        mod.PROBE_OVERRIDE = prober
        out, rc = self._run_check()
        self.assertEqual(rc, 0, out)
        self.assertTrue(timeouts, "expected at least one probe attempt")
        # Never exceeds the remaining budget, nor the default per-probe ceiling.
        self.assertTrue(all(t <= 5 for t in timeouts), timeouts)
        self.assertTrue(all(t <= mod.DEFAULT_PROBE_TIMEOUT for t in timeouts), timeouts)
        self.assertEqual(timeouts[0], 5.0)  # first attempt: full remaining budget (< default 15)


class MainFlowTests(unittest.TestCase):
    """Exercise main()'s vendor-consistency flow with go/git calls stubbed."""

    def setUp(self):
        self._env = dict(os.environ)
        self._cwd = os.getcwd()
        self._orig_sub = mod.subprocess.run
        self._tmp = tempfile.mkdtemp()
        os.chdir(self._tmp)
        with open(os.path.join(self._tmp, "go.mod"), "w", encoding="utf-8") as fh:
            fh.write("module example.com/t\n\ngo 1.22.0\n")
        os.mkdir(os.path.join(self._tmp, "vendor"))
        # Disable the proxy check and go-list; the go/git subcommands are stubbed
        # via subprocess.run below.
        os.environ["CHECK_GOPROXY_AVAILABILITY"] = "false"
        os.environ["CHECK_MOD_LIST"] = "false"
        os.environ.pop("COMPAT", None)
        os.environ.pop("GOWORK", None)

    def tearDown(self):
        os.environ.clear()
        os.environ.update(self._env)
        os.chdir(self._cwd)
        shutil.rmtree(self._tmp, ignore_errors=True)
        mod.subprocess.run = self._orig_sub

    def _stub_subprocess(self, git_status_rc):
        """Stub subprocess.run: all `go` subcommands succeed; `git status`
        returns the requested code. Drives main() to the git-status branch."""
        def fake_run(cmd, *_a, **_k):
            if cmd and cmd[0] == "git":
                return types.SimpleNamespace(
                    returncode=git_status_rc, stdout="", stderr="fatal: boom\n")
            return types.SimpleNamespace(returncode=0, stdout="", stderr="")
        mod.subprocess.run = fake_run

    def _capture_main(self):
        buf = io.StringIO()
        with contextlib.redirect_stdout(buf), contextlib.redirect_stderr(buf):
            rc = mod.main([])
        return buf.getvalue(), rc

    def test_git_status_nonzero_fails(self):
        # B2 parity: a failing `git status` must fail the step (bash errexit),
        # not be treated as "no changes".
        self._stub_subprocess(git_status_rc=1)
        out, rc = self._capture_main()
        self.assertNotEqual(rc, 0)
        self.assertIn("git status", out)

    def test_git_status_clean_passes(self):
        self._stub_subprocess(git_status_rc=0)
        _out, rc = self._capture_main()
        self.assertEqual(rc, 0)


if __name__ == "__main__":
    unittest.main()
