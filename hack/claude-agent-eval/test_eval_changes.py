"""Changed files from JOB_SPEC and a fake GitHub API injected as the opener; no network."""

import contextlib
import email.message
import hashlib
import http.server
import io
import json
import os
from pathlib import Path
import signal
import tempfile
import threading
import unittest
from unittest import mock
import urllib.error
import urllib.parse
import urllib.request

try:
    from . import test_manifest_runner as support
except ImportError:
    import test_manifest_runner as support

changes = support.changes
fake_github = support.fake_github
runner = support.runner
ORG, REPO = support.ORG, support.REPO
HEAD_A, HEAD_B, HEAD_C = "a" * 40, "b" * 40, "c" * 40
PULL_PATH = f"/repos/{ORG}/{REPO}/pulls/7"


def spec(job_type="presubmit", pulls=((7, HEAD_A),), extra_refs=None, **refs):
    document = {"type": job_type, "job": "job", "buildid": "1", "prowjobid": "id",
                "refs": {"org": ORG, "repo": REPO, "base_ref": "main", "base_sha": HEAD_C,
                         "pulls": [{"number": number, "sha": sha, "author": "dev"} for number, sha in pulls],
                         **refs}}
    if extra_refs is not None:
        document["extra_refs"] = extra_refs
    return json.dumps(document)


def modified(*names):
    return [{"filename": name, "status": "modified"} for name in names]


class ChangedFilesTests(unittest.TestCase):  # pylint: disable=too-many-public-methods
    def setUp(self):
        self.sleeps, self.fake, self.output = [], None, ""

    def api(self, pulls=None, responses=None, opener=None, token="token-x"):
        self.fake = fake_github.FakeGitHub({"pulls": pulls or {}, "responses": responses or {}})
        return changes.GitHubAPI(token, opener=opener or self.fake, sleep=self.sleeps.append,
                                 now=lambda: 1000.0, clock=lambda: 0.0, deadline=600.0)

    def changed(self, pulls=None, *, job_spec=None, job_type="presubmit", **fake_api):
        """Select changed files for a job; fake_api (responses, opener) configures the fake API."""
        api = self.api(pulls, **fake_api)
        with contextlib.redirect_stdout(io.StringIO()) as output:
            try:
                return changes.changed_files({"JOB_TYPE": job_type, "JOB_SPEC": job_spec or spec()}, api)
            finally:
                self.output = output.getvalue()

    def assert_error(self, fragment, **kwargs):
        with self.assertRaises(changes.EvalError) as raised:
            self.changed(**kwargs)
        self.assertIn(fragment, str(raised.exception))
        return str(raised.exception)

    def urls(self):
        return [request["url"] for request in self.fake.requests]

    def test_normal_pull_request(self):
        files = self.changed({f"{ORG}/{REPO}#7": {"head_sha": HEAD_A, "files": [
            *modified("skills/foo/SKILL.md"), {"filename": "evals/new.yaml", "status": "added"}]}})
        self.assertEqual(files, ["skills/foo/SKILL.md", "evals/new.yaml"])
        api = "https://api.github.com"
        self.assertEqual(self.urls(), [f"{api}{PULL_PATH}", f"{api}{PULL_PATH}/files?per_page=100", f"{api}{PULL_PATH}"])
        self.assertEqual({(request["authorization"], request["authorization_sha256"]) for request in self.fake.requests},
                         {("Bearer <redacted>", hashlib.sha256(b"Bearer token-x").hexdigest())})
        self.assertIn(f"CHANGES {ORG}/{REPO}#7 at {HEAD_A[:12]}: 2 path(s)", self.output)

    def test_renames_contribute_both_paths_and_copies_only_the_new_one(self):
        files = self.changed({f"{ORG}/{REPO}#7": {"head_sha": HEAD_A, "files": [
            {"filename": "docs/moved.md", "previous_filename": "skills/foo/SKILL.md", "status": "renamed"},
            {"filename": "docs/copy.md", "previous_filename": "docs/guide.md", "status": "copied"}]}})
        self.assertEqual(files, ["docs/moved.md", "skills/foo/SKILL.md", "docs/copy.md"])

    def test_deletions_count(self):
        files = self.changed({f"{ORG}/{REPO}#7": {"head_sha": HEAD_A, "files": [
            {"filename": "skills/foo/SKILL.md", "status": "removed"}]}})
        self.assertEqual(files, ["skills/foo/SKILL.md"])

    def test_pagination_reads_every_page(self):
        names = [f"dir/file-{index:03}" for index in range(250)]
        files = self.changed({f"{ORG}/{REPO}#7": {"head_sha": HEAD_A, "files": modified(*names)}})
        self.assertEqual(files, names)
        pages = [url for url in self.urls() if "/files" in url]
        self.assertEqual(len(pages), 3)
        self.assertTrue(all("per_page=100" in url for url in pages))

    def test_pagination_never_leaves_the_api_origin(self):
        link = '<https://user:link-secret@attacker.example:8443/steal?access_token=leaked-token&page=2>; rel="next"'
        responses = {f"{PULL_PATH}/files": [{"body": modified("a"), "headers": {"Link": link}}]}
        message = self.assert_error("pagination link points to https://attacker.example:8443, outside "
                                    "https://api.github.com", pulls={f"{ORG}/{REPO}#7": {
                                        "head_sha": HEAD_A, "files": modified("a", "b"), "changed_files": 2}},
                                    responses=responses)
        for leaked in ("link-secret", "user:", "leaked-token", "access_token", "/steal", "page=2"):
            self.assertNotIn(leaked, message)

    def test_safe_origin_names_only_scheme_and_host(self):
        for url, expected in (("https://user:pw@api.github.com/x?token=t#f", "https://api.github.com"),
                              ("http://a:b@127.0.0.1:8080/y", "http://127.0.0.1:8080"),
                              ("https://host:notaport/z?token=t", "https://host:<invalid port>"),
                              ("/relative?token=t", "<no scheme>://<unknown host>")):
            with self.subTest(url=url):
                self.assertEqual(changes.safe_origin(urllib.parse.urlsplit(url)), expected)

    def test_more_files_than_github_lists_is_an_error(self):
        self.assert_error("more than the 3000", pulls={f"{ORG}/{REPO}#7": {
            "head_sha": HEAD_A, "files": modified("a"), "changed_files": 3001}})
        self.assertFalse(any("/files" in url for url in self.urls()))

    def test_truncated_listing_is_an_error_not_a_subset(self):
        names = [f"file-{index}" for index in range(150)]
        self.assert_error("refusing an incomplete file list", pulls={f"{ORG}/{REPO}#7": {
            "head_sha": HEAD_A, "files": modified(*names), "list_limit": 100}})

    def test_head_moved_before_listing_is_an_error(self):
        message = self.assert_error("changed after the job started",
                                    pulls={f"{ORG}/{REPO}#7": {"head_sha": HEAD_B, "files": modified("a")}})
        self.assertIn(HEAD_A, message)
        self.assertFalse(any("/files" in url for url in self.urls()))

    def test_head_moved_while_listing_is_an_error(self):
        pull = {"number": 7, "changed_files": 1, "base": {"ref": "main"}}
        responses = {PULL_PATH: [{"body": {**pull, "head": {"sha": HEAD_A}}},
                                 {"body": {**pull, "head": {"sha": HEAD_B}}}]}
        self.assert_error("changed after the job started", responses=responses,
                          pulls={f"{ORG}/{REPO}#7": {"head_sha": HEAD_A, "files": modified("a")}})

    def test_base_retargeted_before_listing_is_an_error(self):
        message = self.assert_error("retargeted after the job started", pulls={f"{ORG}/{REPO}#7": {
            "head_sha": HEAD_A, "base_ref": "release-4.22", "files": modified("a")}})
        self.assertIn("'release-4.22'", message)
        self.assertIn("'main'", message)
        self.assertFalse(any("/files" in url for url in self.urls()))

    def test_base_retargeted_while_listing_is_an_error(self):
        pull = {"number": 7, "changed_files": 1, "head": {"sha": HEAD_A}}  # The head never changes.
        responses = {PULL_PATH: [{"body": {**pull, "base": {"ref": "main"}}},
                                 {"body": {**pull, "base": {"ref": "release-4.22"}}}]}
        self.assert_error("retargeted after the job started", responses=responses,
                          pulls={f"{ORG}/{REPO}#7": {"head_sha": HEAD_A, "files": modified("a")}})

    def test_matching_base_passes_and_an_absent_base_ref_is_not_compared(self):
        pulls = {f"{ORG}/{REPO}#7": {"head_sha": HEAD_A, "base_ref": "main", "files": modified("a")}}
        self.assertEqual(self.changed(pulls), ["a"])
        document = json.loads(spec())
        del document["refs"]["base_ref"]
        retargeted = {f"{ORG}/{REPO}#7": {"head_sha": HEAD_A, "base_ref": "release-4.22", "files": modified("a")}}
        self.assertEqual(self.changed(retargeted, job_spec=json.dumps(document)), ["a"])

    def test_batch_is_the_union_of_every_pull(self):
        files = self.changed({f"{ORG}/{REPO}#7": {"head_sha": HEAD_A, "files": modified("a", "shared")},
                              f"{ORG}/{REPO}#8": {"head_sha": HEAD_B, "files": modified("shared", "b")}},
                             job_spec=spec("batch", ((7, HEAD_A), (8, HEAD_B))), job_type="batch")
        self.assertEqual(files, ["a", "shared", "b"])

    def test_batch_guards_the_head_of_every_pull(self):
        self.assert_error(f"{ORG}/{REPO}#8 head is", job_type="batch",
                          job_spec=spec("batch", ((7, HEAD_A), (8, HEAD_B))),
                          pulls={f"{ORG}/{REPO}#7": {"head_sha": HEAD_A, "files": modified("a")},
                                 f"{ORG}/{REPO}#8": {"head_sha": HEAD_C, "files": modified("b")}})

    def test_rehearsal_selects_nothing_without_any_api_call(self):
        rehearsal = spec(pulls=((88000, HEAD_A),), org="openshift", repo="release",
                         extra_refs=[{"org": ORG, "repo": REPO, "base_ref": "main", "workdir": True}])
        with contextlib.redirect_stdout(io.StringIO()) as output:  # No client: it must not be needed.
            self.assertEqual(changes.changed_files({"JOB_TYPE": "presubmit", "JOB_SPEC": rehearsal}), [])
        self.assertIn(f"NO-PR: the checkout under test is {ORG}/{REPO}@main", output.getvalue())
        self.assertIn("openshift/release#88000", output.getvalue())
        self.assertEqual(self.changed(job_spec=rehearsal), [])
        self.assertEqual(self.fake.requests, [])

    def test_workdir_ref_decides_the_repository(self):
        extra = [{"org": "other", "repo": "tools", "base_ref": "main"}]  # Not the workdir: ignored.
        files = self.changed({f"{ORG}/{REPO}#7": {"head_sha": HEAD_A, "files": modified("a")}},
                             job_spec=spec(extra_refs=extra))
        self.assertEqual(files, ["a"])

    def test_missing_or_invalid_job_spec(self):
        document = json.loads(spec())
        refs = document["refs"]
        cases = {
            "": "requires Prow's JOB_SPEC", "{": "not valid JSON", "[]": "must be a JSON object",
            json.dumps({**document, "type": "periodic"}): "does not match JOB_TYPE",
            json.dumps({**document, "refs": None}): "must contain refs",
            json.dumps({**document, "extra_refs": {}}): "extra_refs must be a list",
            json.dumps({**document, "refs": {**refs, "org": "../x"}}): "GitHub owner name",
            json.dumps({**document, "refs": {**refs, "repo": "a/b"}}): "GitHub repository name",
            json.dumps({**document, "refs": {**refs, "pulls": []}}): "exactly one pull",
            json.dumps({**document, "refs": {**refs, "pulls": [{"number": 7, "sha": HEAD_A},
                                                               {"number": 8, "sha": HEAD_B}]}}): "exactly one pull",
            json.dumps({**document, "refs": {**refs, "pulls": [{"number": "7", "sha": HEAD_A}]}}): "positive integer",
            json.dumps({**document, "refs": {**refs, "pulls": [{"number": 7, "sha": "abc123"}]}}): "40-character",
        }
        for job_spec, fragment in cases.items():
            with self.subTest(job_spec=job_spec[:50]):
                self.assert_error(fragment, job_spec=job_spec or " ")
        self.assert_error("at least one pull", job_type="batch",
                          job_spec=json.dumps({**document, "type": "batch", "refs": {**refs, "pulls": []}}))
        self.assert_error("supports JOB_TYPE", job_type="postsubmit", job_spec=spec("postsubmit"))

    def test_private_or_missing_pull_request_explains_the_token(self):
        message = self.assert_error("HTTP 404", pulls={})
        self.assertIn("private repository", message)
        self.assertIn("GITHUB_TOKEN_PATH", message)
        self.assertNotIn("token-x", message)

    def test_rejected_token_is_an_error(self):
        responses = {PULL_PATH: [{"status": 401, "body": {"message": "Bad credentials"}}]}
        message = self.assert_error("rejected the token", responses=responses)
        self.assertIn("Bad credentials", message)
        self.assertEqual(self.sleeps, [])

    def test_forbidden_without_rate_limit_is_not_retried(self):
        responses = {PULL_PATH: [{"status": 403, "body": {"message": "Resource not accessible by integration"}}]}
        self.assert_error("HTTP 403: Resource not accessible", responses=responses)
        self.assertEqual(self.sleeps, [])

    def test_rate_limits_wait_as_github_documents_then_succeed(self):
        pulls = {f"{ORG}/{REPO}#7": {"head_sha": HEAD_A, "files": modified("a")}}
        for reply, wait in (
                ({"status": 403, "headers": {"x-ratelimit-remaining": "0", "x-ratelimit-reset": "1005"}}, 6.0),
                ({"status": 429, "headers": {"retry-after": "3"}}, 3.0),
                ({"status": 403, "body": {"message": "You have exceeded a secondary rate limit"}}, 60.0),
                ({"status": 429}, 60.0),  # A 429 is a rate limit even without headers or message.
                ({"status": 502}, 2.0)):
            with self.subTest(reply=reply):
                self.sleeps.clear()
                self.assertEqual(self.changed(pulls, responses={PULL_PATH: [reply]}), ["a"])
                self.assertEqual(self.sleeps, [wait])
                self.assertIn("retrying in", self.output)

    def test_rate_limited_429_without_headers_retries_a_bounded_number_of_times(self):
        responses = {PULL_PATH: [{"status": 429}] * 4}
        self.assert_error("beyond the selection time limit", responses=responses)
        self.assertEqual(self.sleeps, [60.0, 120.0])  # The next backoff (240 s) exceeds the cap.

    def test_incomplete_body_is_retried_then_fails_closed(self):
        pulls = {f"{ORG}/{REPO}#7": {"head_sha": HEAD_A, "files": modified("a")}}
        self.assertEqual(self.changed(pulls, responses={PULL_PATH: [{"incomplete": True}]}), ["a"])
        self.assertEqual(self.sleeps, [2.0])
        self.sleeps.clear()
        message = self.assert_error("gave up after 4 attempts", pulls=pulls,
                                    responses={PULL_PATH: [{"incomplete": True}] * 4})
        self.assertIn("IncompleteRead", message)
        self.assertEqual(self.sleeps, [2.0, 4.0, 8.0])

    def test_incomplete_body_reaches_the_eval_selection_junit_failure(self):
        api = self.api(responses={PULL_PATH: [{"incomplete": True}] * 4})
        with tempfile.TemporaryDirectory() as directory:
            repo, artifacts = Path(directory) / "repo", Path(directory) / "artifacts"
            (repo / "evals").mkdir(parents=True)
            (repo / "evals/eval.yaml").write_text("name: example\n", encoding="utf-8")
            (repo / "evals.yaml").write_text(json.dumps({"evals": [{
                "config": "evals/eval.yaml", "run": "pr", "parallelism": 1, "max_turns": 1,
                "triggers": ["skills/"]}]}), encoding="utf-8")
            env = {"EVAL_WORKDIR": str(repo), "ARTIFACT_DIR": str(artifacts), "JOB_TYPE": "presubmit",
                   "JOB_SPEC": spec(), "PATH": os.environ.get("PATH", "")}
            handlers = signal.getsignal(signal.SIGTERM), signal.getsignal(signal.SIGINT)
            try:
                with mock.patch.dict(os.environ, env, clear=True), \
                        mock.patch.object(changes.GitHubAPI, "from_env", return_value=api), \
                        contextlib.redirect_stdout(io.StringIO()) as output:
                    status = runner.main()
            finally:
                signal.signal(signal.SIGTERM, handlers[0])
                signal.signal(signal.SIGINT, handlers[1])
            self.assertEqual(status, 1, output.getvalue())
            junit = (artifacts / "junit_claude-eval.xml").read_text(encoding="utf-8")
        self.assertIn('failures="1"', junit)
        self.assertIn("eval selection", junit)
        self.assertIn("IncompleteRead", junit)

    def test_request_log_redacts_the_authorization_value(self):
        with tempfile.TemporaryDirectory() as directory:
            log = Path(directory) / "requests.jsonl"
            fake = fake_github.FakeGitHub({"pulls": {f"{ORG}/{REPO}#7": {"head_sha": HEAD_A, "files": modified("a")}}},
                                          log=str(log))
            api = changes.GitHubAPI("secret-token", opener=fake, sleep=self.sleeps.append)
            with contextlib.redirect_stdout(io.StringIO()):
                self.assertEqual(changes.changed_files({"JOB_TYPE": "presubmit", "JOB_SPEC": spec()}, api), ["a"])
            text = log.read_text(encoding="utf-8")
        self.assertNotIn("secret-token", text)
        records = [json.loads(line) for line in text.splitlines()]
        self.assertEqual(len(records), 3)
        self.assertEqual({record["authorization"] for record in records}, {"Bearer <redacted>"})
        self.assertEqual({record["authorization_sha256"] for record in records},
                         {hashlib.sha256(b"Bearer secret-token").hexdigest()})

    def test_rate_limit_beyond_the_selection_deadline_fails_without_waiting(self):
        responses = {PULL_PATH: [{"status": 403, "headers": {"x-ratelimit-remaining": "0",
                                                              "x-ratelimit-reset": "9000"}}]}
        self.assert_error("beyond the selection time limit", responses=responses)
        self.assertEqual(self.sleeps, [])

    def test_retries_are_bounded(self):
        responses = {PULL_PATH: [{"status": 503}] * 4}
        self.assert_error("gave up after 4 attempts", responses=responses)
        self.assertEqual(self.sleeps, [2.0, 4.0, 8.0])

    def test_network_errors_are_retried(self):
        failures = [urllib.error.URLError("connection reset")]

        def flaky(request, timeout=None):
            if failures:
                raise failures.pop()
            return self.fake(request, timeout=timeout)

        pulls = {f"{ORG}/{REPO}#7": {"head_sha": HEAD_A, "files": modified("a")}}
        self.assertEqual(self.changed(pulls, opener=flaky), ["a"])
        self.assertEqual(self.sleeps, [2.0])

    def test_invalid_responses_are_errors(self):
        pulls = {f"{ORG}/{REPO}#7": {"head_sha": HEAD_A, "files": modified("a")}}
        for responses, fragment in (({PULL_PATH: [{"body": "not json"}]}, "invalid JSON"),
                                    ({PULL_PATH: [{"body": {"head": {"sha": HEAD_A}}}]}, "changed_files"),
                                    ({f"{PULL_PATH}/files": [{"body": {"a": 1}}]}, "list of files")):
            with self.subTest(fragment=fragment):
                self.assert_error(fragment, pulls=pulls, responses=responses)
        for name in ("../escape", "/absolute", "", "a//b"):
            with self.subTest(name=name):
                self.assert_error("invalid repository path", pulls={f"{ORG}/{REPO}#7": {
                    "head_sha": HEAD_A, "files": [{"filename": name, "status": "added"}]}})

    def test_token_comes_from_the_mounted_file(self):
        with tempfile.TemporaryDirectory() as directory:
            token = Path(directory) / "token"
            token.write_text("secret-value\n", encoding="utf-8")
            with contextlib.redirect_stdout(io.StringIO()) as output:
                self.assertEqual(changes.GitHubAPI.from_env({"GITHUB_TOKEN_PATH": str(token)}).token,
                                 "secret-value")
                missing = changes.GitHubAPI.from_env({"GITHUB_TOKEN_PATH": str(token) + ".missing"})
            self.assertEqual(missing.token, "")
            self.assertNotIn("Authorization", missing.headers())
            self.assertIn("unauthenticated", output.getvalue())
            self.assertNotIn("secret-value", output.getvalue())

    def test_runner_accepts_batch_jobs_and_rejects_other_types(self):
        self.assertEqual(runner.select_manifest_entries.__kwdefaults__, {"github": None})
        with tempfile.TemporaryDirectory() as directory:
            repo = Path(directory)
            (repo / "evals.yaml").write_text("evals: []\n", encoding="utf-8")
            for job_type in ("presubmit", "batch"):
                self.assertEqual(runner.select_manifest_entries(repo, {"JOB_TYPE": job_type}), ([], []))
            for job_type in ("periodic", "postsubmit"):
                with self.assertRaises(runner.EvalError):
                    runner.select_manifest_entries(repo, {"JOB_TYPE": job_type})


class RedirectGuardTests(unittest.TestCase):
    """The default opener follows redirects only within the API origin, so the token stays there."""

    def setUp(self):
        # Loopback servers stand in for GitHub and another host; never route them via a proxy.
        environ = mock.patch.dict(os.environ, {key: value for key, value in os.environ.items()
                                               if "proxy" not in key.lower()}, clear=True)
        environ.start()
        self.addCleanup(environ.stop)

    def serve(self, respond):
        seen = []

        class Handler(http.server.BaseHTTPRequestHandler):
            def do_GET(self):  # pylint: disable=invalid-name
                seen.append({"path": self.path, "authorization": self.headers.get("Authorization")})
                status, headers, body = respond(self.path)
                self.send_response(status)
                for key, value in headers.items():
                    self.send_header(key, value)
                self.send_header("Content-Length", str(len(body)))
                self.end_headers()
                self.wfile.write(body)

            def log_message(self, *args):  # pylint: disable=arguments-differ
                pass

        server = http.server.ThreadingHTTPServer(("127.0.0.1", 0), Handler)
        threading.Thread(target=server.serve_forever, daemon=True).start()
        self.addCleanup(server.server_close)
        self.addCleanup(server.shutdown)
        return f"http://127.0.0.1:{server.server_port}", seen

    def test_off_origin_redirect_is_refused_before_the_token_is_sent(self):
        other, stolen = self.serve(lambda path: (200, {}, b"{}"))
        location = other.replace("http://", "http://user:redirect-secret@") + "/collect?access_token=leaked-token"
        origin, seen = self.serve(lambda path: (302, {"Location": location}, b""))
        api = changes.GitHubAPI("secret-token", base_url=origin, sleep=lambda seconds: None)
        with self.assertRaises(changes.EvalError) as raised:
            api.get(f"/repos/{ORG}/{REPO}/pulls/7")
        message = str(raised.exception)
        self.assertIn(f"redirected (HTTP 302) to {other}; refusing to send credentials outside {origin}", message)
        for leaked in ("secret-token", "redirect-secret", "user:", "leaked-token", "access_token", "/collect"):
            self.assertNotIn(leaked, message)
        self.assertEqual(seen, [{"path": f"/repos/{ORG}/{REPO}/pulls/7", "authorization": "Bearer secret-token"}])
        self.assertEqual(stolen, [])

    def test_same_origin_redirect_is_followed_with_the_token(self):
        def respond(path):
            if path.startswith("/repos/"):  # e.g. a renamed repository
                return 301, {"Location": "/repositories/1/pulls/7"}, b""
            return 200, {"Content-Type": "application/json"}, b'{"ok": true}'

        origin, seen = self.serve(respond)
        api = changes.GitHubAPI("secret-token", base_url=origin, sleep=lambda seconds: None)
        self.assertEqual(api.get(f"/repos/{ORG}/{REPO}/pulls/7"), {"ok": True})
        self.assertEqual([request["authorization"] for request in seen], ["Bearer secret-token"] * 2)

    def test_https_to_http_redirect_is_refused(self):
        handler = changes.SameOriginRedirects(urllib.parse.urlsplit(changes.API_URL))
        request = urllib.request.Request(f"{changes.API_URL}/repos/{ORG}/{REPO}/pulls/7",
                                         headers={"Authorization": "Bearer t"})
        for target, shown in (("http://api.github.com/repos/o/r/pulls/7", "http://api.github.com"),
                              ("https://u:pw@example.com/repos/o/r/pulls/7?token=leak", "https://example.com")):
            with self.subTest(target=target), self.assertRaises(changes.EvalError) as raised:
                handler.redirect_request(request, io.BytesIO(), 302, "Found", email.message.Message(), target)
            self.assertIn(f"to {shown};", str(raised.exception))
            for leaked in ("pw", "u:", "leak", "/repos/"):
                self.assertNotIn(leaked, str(raised.exception))
        followed = handler.redirect_request(request, io.BytesIO(), 301, "Moved", email.message.Message(),
                                            "https://api.github.com/repositories/1/pulls/7")
        self.assertEqual(followed.get_header("Authorization"), "Bearer t")


if __name__ == "__main__":
    unittest.main()
