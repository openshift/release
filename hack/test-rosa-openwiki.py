#!/usr/bin/env python3
"""Offline regression tests for the shared ROSA OpenWiki steps.

Uses real Git/bundles and fixture App keys. All network, package installation,
and model calls are mocked; no CI secrets or model quota are needed.
"""

import json
import os
from pathlib import Path
import shutil
import subprocess
import tempfile
import unittest

ROOT = Path(__file__).resolve().parents[1]
STEPS = ROOT / "ci-operator/step-registry/rosa/boundary/openwiki"
REPO = "openshift-online/rosa-cora-agent"
JOB = "periodic-ci-openshift-online-rosa-cora-agent-main-openwiki-openwiki-update"

MOCK_TOOL = r"""
#!/usr/bin/env python3
import json
import os
from pathlib import Path
import subprocess
import sys

name = Path(sys.argv[0]).name
args = sys.argv[1:]
root = Path(os.environ["MOCK_ROOT"])
real_git = os.environ["REAL_GIT"]


def log(**event):
    with (root / "events.jsonl").open("a") as stream:
        stream.write(json.dumps({"tool": name, **event}) + "\n")


def git(*arguments):
    return subprocess.check_output([real_git, *arguments], text=True).strip()


def token_permission():
    token = os.environ.get("GITHUB_TOKEN")
    assert token in ("mock-read-token", "mock-write-token"), "missing fixture token"
    assert os.environ.get("GH_TOKEN") == token, "gh must use the scoped token"
    return token.split("-")[1]


if name == "git":
    commands = {
        "clone", "fetch", "ls-remote", "push", "config", "switch", "merge",
        "bundle", "remote", "apply", "diff", "write-tree", "commit", "add",
        "check-ref-format", "ls-files", "rev-parse",
    }
    command = next(argument for argument in args if argument in commands)
    if command in ("clone", "fetch", "ls-remote", "push") and (
        "origin" in args or any(arg.startswith("https://github.com/") for arg in args)
    ):
        permission = token_permission()
        assert os.environ.get("GIT_TERMINAL_PROMPT") == "0"
        askpass = os.environ["GIT_ASKPASS"]
        password = subprocess.check_output([askpass, "Password:"], text=True).strip()
        assert password == os.environ["GITHUB_TOKEN"]
        if command == "push":
            assert permission == "write", "read-only token must never push"
            race = os.environ.get("MOCK_BRANCH_RACE")
            if race:
                operation = ["update-ref", "refs/heads/openwiki/update"]
                if race == "delete":
                    operation = ["update-ref", "-d", "refs/heads/openwiki/update"]
                else:
                    revision = "MOCK_FIRST_SHA" if race == "rewind" else "MOCK_MAIN_SHA"
                    operation.append(os.environ[revision])
                subprocess.check_call([real_git, "-C", os.environ["MOCK_REMOTE"], *operation])
        args = [
            os.environ["MOCK_REMOTE"] if arg == "https://github.com/" + os.environ["TARGET_REPO"] + ".git"
            else arg for arg in args
        ]
    log(command=command, args=args)
    os.execv(real_git, [real_git, *args])
elif name == "curl":
    if args[-1].endswith("/access_tokens"):
        payload = json.loads(args[args.index("--data") + 1])
        assert payload["repositories"] == [os.environ["TARGET_REPO"].split("/")[1]]
        permission = payload["permissions"]["contents"]
        assert payload["permissions"] == {
            "contents": permission, "pull_requests": permission,
        }
        assert permission in ("read", "write")
        log(permissions=payload["permissions"], repositories=payload["repositories"])
        print(json.dumps({"token": "mock-" + permission + "-token"}))
    elif "-o" in args and any("nodejs.org/dist/v22.22.0/" in arg for arg in args):
        Path(args[args.index("-o") + 1]).write_bytes(b"fixture Node archive")
        log(installation="node")
    else:
        raise AssertionError("unexpected network request")
elif name == "gh":
    permission = token_permission()
    if args[:2] == ["pr", "list"]:
        count_file = root / "pr-list-count"
        count = int(count_file.read_text()) + 1 if count_file.exists() else 1
        count_file.write_text(str(count))
        prs = os.environ.get("MOCK_PRS", "[]")
        if count >= int(os.environ.get("MOCK_PR_CHANGE_AT", "999")):
            prs = os.environ.get("MOCK_PRS_AFTER", "[]")
        assert args[args.index("--json") + 1] == "number,headRepository"
        query = args[args.index("--jq") + 1]
        result = subprocess.run(["jq", "-r", query], input=prs, text=True, check=True, capture_output=True)
        log(action="list", args=args, permission=permission)
        print(result.stdout, end="")
    else:
        assert permission == "write", "read-only token must never write PRs"
        log(action="write", args=args, permission=permission)
        if args[:2] == ["pr", "create"]:
            print("https://github.com/" + os.environ["TARGET_REPO"] + "/pull/42")
        else:
            assert args[0] == "api" and "PATCH" in args
elif name == "uname":
    assert args == ["-m"]
    print("x86_64")
elif name == "sha256sum":
    assert args == ["-c", "-"]
    assert len(sys.stdin.read().split()[0]) == 64
    print("fixture Node archive: OK")
elif name == "tar":
    assert args[0] == "-xJf"
elif name == "npm":
    assert args[:2] == ["install", "--global"]
    assert args[-3:] == ["openwiki@0.7.1", "mermaid@11.16.0", "jsdom@29.1.1"]
    prefix = Path(args[args.index("--prefix") + 1])
    package = prefix / "lib/node_modules/openwiki/package.json"
    package.parent.mkdir(parents=True)
    package.write_text('{"version":"0.7.1"}')
    log(installation="openwiki")
elif name == "openwiki":
    assert args == ["code", "--update", "--print"]
    for key in ("GITHUB_TOKEN", "GH_TOKEN", "GIT_ASKPASS"):
        assert key not in os.environ, "GitHub credentials reached the model"
    assert os.environ["LANGCHAIN_TRACING_V2"] == "false"
    assert os.environ["OPENWIKI_PROVIDER"] == "gemini-enterprise"
    assert os.environ["OPENWIKI_MODEL_ID"] == "claude-sonnet-5"
    assert not Path(".git/shallow").exists()
    assert git("remote", "get-url", "origin") == "https://github.com/" + os.environ["TARGET_REPO"] + ".git"
    assert os.environ["MOCK_FIRST_SHA"] in git("rev-list", "HEAD").splitlines()
    assert Path("new-source.txt").exists(), "latest base was not merged"
    if os.environ.get("MOCK_EXPECT_EXISTING") == "1":
        assert Path("openwiki/prior.md").exists(), "existing PR pages were lost"
    Path("openwiki/index.md").write_text("# Updated wiki\n\nMarkdown hard break.  \n")
    Path("openwiki/claims.json").write_text('{"claims":[]}\n')
    Path("openwiki/.run.json").write_text('{"transient":true}\n')
    Path("AGENTS.md").write_text("Model root guidance must not be published.\n")
    Path("source.txt").write_text("Model source changes must not be published.\n")
    hook = Path(".git/hooks/pre-commit")
    hook.write_text("#!/bin/sh\nexit 99\n")
    hook.chmod(0o700)
    subprocess.check_call([real_git, "add", "-A"])
    log(action="model")
    sys.exit(int(os.environ.get("MOCK_OPENWIKI_STATUS", "0")))
else:
    raise AssertionError("unexpected tool: " + name)
"""


# Fixture state and one public method per scenario are intentional in unittest.
# pylint: disable=too-many-instance-attributes,too-many-public-methods
class OpenWikiStepsTest(unittest.TestCase):
    """Exercise real script control flow without external access."""

    def setUp(self):
        self.root = Path(tempfile.mkdtemp(prefix="rosa-openwiki-test-"))
        self.addCleanup(shutil.rmtree, self.root)
        self.bin = self.root / "bin"
        self.bin.mkdir()
        self.shared = self.root / "shared"
        self.shared.mkdir()
        self.seed = self.root / "seed"
        self.remote = self.root / "remote.git"
        self.real_git = shutil.which("git")

        # Do not let tests inherit personal auth, signing, hooks, or Git config.
        self.env = {
            key: value for key, value in os.environ.items()
            if not key.startswith(("GIT_", "GH_", "GITHUB_", "OPENWIKI_", "MOCK_"))
        }
        self.env.update({
            "HOME": str(self.root / "home"),
            "GIT_CONFIG_NOSYSTEM": "1",
            "GIT_CONFIG_GLOBAL": os.devnull,
            # Only local fixture/bundle transports may reach real Git.
            "GIT_CONFIG_COUNT": "2",
            "GIT_CONFIG_KEY_0": "protocol.allow",
            "GIT_CONFIG_VALUE_0": "never",
            "GIT_CONFIG_KEY_1": "protocol.file.allow",
            "GIT_CONFIG_VALUE_1": "always",
            "PATH": str(self.bin) + os.pathsep + os.environ["PATH"],
            "REAL_GIT": self.real_git,
            "MOCK_ROOT": str(self.root),
            "MOCK_REMOTE": str(self.remote),
            "TARGET_REPO": REPO,
            "TARGET_BASE_BRANCH": "main",
            "TARGET_UPDATE_BRANCH": "openwiki/update",
            "TARGET_PERIODIC_JOB": JOB,
            "JOB_NAME": JOB,
            "BUILD_ID": "123456",
            "SHARED_DIR": str(self.shared),
            "TARGET_PROVIDER": "gemini-enterprise",
            "TARGET_MODEL_ID": "claude-sonnet-5",
            "TARGET_VERTEX_PROJECT_ID": "rosa-general",
            "TARGET_VERTEX_SERVICE_ACCOUNT_EMAIL": "rosa-boundary@rosa-general.iam.gserviceaccount.com",
        })
        Path(self.env["HOME"]).mkdir()
        self.git("init", "-b", "main", str(self.seed))
        self.git("-C", str(self.seed), "config", "user.name", "Fixture")
        self.git("-C", str(self.seed), "config", "user.email", "fixture@example.invalid")
        (self.seed / "openwiki").mkdir()
        (self.seed / "openwiki/index.md").write_text("# Original wiki\n")
        (self.seed / "source.txt").write_text("Original source\n")
        self.commit("initial")
        self.env["MOCK_FIRST_SHA"] = self.git("-C", str(self.seed), "rev-parse", "HEAD")
        self.git("-C", str(self.seed), "switch", "-c", "openwiki/update")
        (self.seed / "openwiki/prior.md").write_text("# Prior completed page\n")
        self.commit("prior docs")
        self.git("-C", str(self.seed), "switch", "main")
        (self.seed / "new-source.txt").write_text("New source on main\n")
        self.commit("new source")
        self.env["MOCK_MAIN_SHA"] = self.git("-C", str(self.seed), "rev-parse", "HEAD")
        self.git("clone", "--bare", str(self.seed), str(self.remote))

        self.app_id = self.root / "app-id"
        self.installation = self.root / "installation"
        self.key = self.root / "app.pem"
        self.app_id.write_text("123\n")
        self.installation.write_text("456\n")
        subprocess.run([
            "openssl", "genpkey", "-algorithm", "RSA", "-pkeyopt",
            "rsa_keygen_bits:2048", "-out", str(self.key),
        ], check=True, capture_output=True)
        vertex = self.root / "vertex.json"
        vertex.write_text(json.dumps({
            "type": "service_account", "project_id": "rosa-general",
            "client_email": self.env["TARGET_VERTEX_SERVICE_ACCOUNT_EMAIL"],
        }))
        self.env["GOOGLE_APPLICATION_CREDENTIALS"] = str(vertex)

        mock = self.bin / "mock-tool"
        mock.write_text(MOCK_TOOL.lstrip())
        mock.chmod(0o700)
        for name in ("git", "curl", "gh", "uname", "sha256sum", "tar", "npm", "openwiki"):
            (self.bin / name).symlink_to(mock)

    def git(self, *args):
        result = subprocess.run(
            [self.real_git, *args], env=self.env, text=True,
            capture_output=True, check=True,
        )
        return result.stdout.rstrip("\n")

    def commit(self, message):
        self.git("-C", str(self.seed), "add", "-A")
        self.git("-C", str(self.seed), "commit", "-m", message)

    def run_step(self, step, expected=0, **overrides):
        script = STEPS / step / ("rosa-boundary-openwiki-" + step + "-commands.sh")
        source = script.read_text()
        replacements = {
            "/var/run/rosa-boundary-github-app-id/github-app-app-id": self.app_id,
            "/var/run/rosa-boundary-github-app-installation/github-app-installation-id": self.installation,
            "/var/run/rosa-boundary-github-app-key/github-app-pem": self.key,
        }
        for old, new in replacements.items():
            source = source.replace(old, str(new))
        local_script = self.root / (step + ".sh")
        local_script.write_text(source)
        result = subprocess.run(
            ["bash", str(local_script)], env={**self.env, **overrides},
            cwd=self.root, text=True, capture_output=True, check=False,
        )
        if expected is not None:
            self.assertEqual(result.returncode, expected, result.stdout + result.stderr)
        return result

    def events(self):
        path = self.root / "events.jsonl"
        return [json.loads(line) for line in path.read_text().splitlines()] if path.exists() else []

    def clear_events(self):
        (self.root / "events.jsonl").write_text("")
        (self.root / "pr-list-count").write_text("0")

    def prs(self, *repositories):
        return json.dumps([
            {"number": number, "headRepository": {"nameWithOwner": repository}}
            for number, repository in repositories
        ])

    def pipeline(self, **overrides):
        self.env.update(overrides)
        self.run_step("prepare")
        self.run_step("update")
        self.clear_events()

    def patch(self, path="openwiki/index.md", content="# Manual update\n", status=0):
        target = self.seed / path
        target.write_text(content)
        self.git("-C", str(self.seed), "add", "-A")
        diff = self.git("-C", str(self.seed), "diff", "--cached", "--binary")
        (self.shared / "openwiki-docs.patch").write_text(diff + "\n")
        for name, value in {
            "openwiki-base-branch": "main", "openwiki-exit-status": str(status),
            "openwiki-prepared-pr": "none",
            "openwiki-version": "0.7.1", "openwiki-model-id": "claude-sonnet-5",
            "openwiki-provider": "gemini-enterprise",
        }.items():
            (self.shared / name).write_text(value + "\n")

    def assert_no_publication(self):
        for event in self.events():
            if event["tool"] == "git":
                self.assertNotIn(event["command"], ("commit", "push"))
            if event["tool"] == "gh":
                self.assertEqual(event["action"], "list")

    def test_prepare_is_read_only_and_ignores_fork_and_stale_branch(self):
        self.run_step("prepare", MOCK_PRS=self.prs((88, "fork/rosa-cora-agent")))
        self.assertEqual((self.shared / "openwiki-base-branch").read_text().strip(), "main")
        bundle = self.shared / "openwiki-source.bundle"
        clone = self.root / "bundle-check"
        self.git("clone", "--branch", "main", str(bundle), str(clone))
        self.assertEqual(self.git("-C", str(clone), "rev-list", "--count", "HEAD"), "2")
        self.assertNotIn("origin/openwiki/update", self.git("-C", str(clone), "branch", "-r"))
        self.assertNotIn(b"mock-read-token", bundle.read_bytes())
        self.assertTrue(all(path.is_file() for path in self.shared.iterdir()))
        tokens = [event for event in self.events() if event["tool"] == "curl"]
        self.assertEqual(tokens[0]["permissions"], {"contents": "read", "pull_requests": "read"})

    def test_open_pr_bundle_preserves_full_histories_and_merges_main(self):
        self.env.update(MOCK_PRS=self.prs((42, REPO)), MOCK_EXPECT_EXISTING="1")
        self.run_step("prepare")
        self.assertEqual((self.shared / "openwiki-base-branch").read_text().strip(), "openwiki/update")
        heads = self.git("bundle", "list-heads", str(self.shared / "openwiki-source.bundle"))
        self.assertIn("refs/heads/main", heads)
        self.assertIn("refs/heads/openwiki/update", heads)
        self.run_step("update")
        patch = (self.shared / "openwiki-docs.patch").read_text()
        self.assertIn("openwiki/index.md", patch)
        for excluded in ("AGENTS.md", "source.txt", ".run.json"):
            self.assertNotIn(excluded, patch)

    def test_update_missing_bundle_fails_before_installation(self):
        self.run_step("update", expected=1)
        self.assertFalse(any(event["tool"] in ("npm", "openwiki", "curl") for event in self.events()))

    def test_update_rejects_wrong_vertex_identity(self):
        self.run_step("update", expected=1, TARGET_VERTEX_PROJECT_ID="other-project")
        self.assertFalse(any(event["tool"] in ("curl", "npm", "openwiki") for event in self.events()))

    def test_rehearsal_authenticates_read_only_without_publishing(self):
        self.pipeline()
        before = self.git("-C", str(self.remote), "show-ref")
        result = self.run_step("publish", JOB_NAME="rehearse-123-" + JOB)
        self.assertIn("patch applies cleanly", result.stdout)
        self.assert_no_publication()
        self.assertFalse(any(event["tool"] == "gh" for event in self.events()))
        self.assertEqual(before, self.git("-C", str(self.remote), "show-ref"))
        token = next(event for event in self.events() if event["tool"] == "curl")
        self.assertEqual(token["permissions"], {"contents": "read", "pull_requests": "read"})

    def test_rehearsal_existing_pr_merges_without_commit(self):
        self.pipeline(MOCK_PRS=self.prs((42, REPO)), MOCK_EXPECT_EXISTING="1")
        self.run_step("publish", JOB_NAME="rehearse-456-" + JOB)
        self.assert_no_publication()
        merges = [event for event in self.events() if event.get("command") == "merge"]
        self.assertEqual(len(merges), 1)
        self.assertIn("--no-commit", merges[0]["args"])
        self.assertIn("--no-ff", merges[0]["args"])

    def test_production_publishes_docs_only_partial_pr_then_fails(self):
        self.pipeline(MOCK_OPENWIKI_STATUS="7")
        self.assertEqual((self.shared / "openwiki-exit-status").read_text().strip(), "7")
        self.run_step("publish", expected=7)
        token = next(event for event in self.events() if event["tool"] == "curl")
        self.assertEqual(token["permissions"], {"contents": "write", "pull_requests": "write"})
        changed = self.git("-C", str(self.remote), "diff", "--name-only", "main", "openwiki/update").splitlines()
        self.assertTrue(changed)
        self.assertTrue(all(path.startswith("openwiki/") for path in changed))
        self.assertNotIn("openwiki/.run.json", changed)
        self.assertEqual(self.git("-C", str(self.remote), "rev-parse", "main"), self.env["MOCK_MAIN_SHA"])
        writes = [event for event in self.events() if event["tool"] == "gh" and event["action"] == "write"]
        self.assertEqual(len(writes), 1)
        self.assertEqual(writes[0]["args"][:2], ["pr", "create"])
        self.assertIn("**Partial update:**", " ".join(writes[0]["args"]))

    def test_boundary_target_uses_same_bundle_and_publisher(self):
        boundary_job = "periodic-ci-openshift-online-rosa-boundary-main-openwiki-openwiki-update"
        self.pipeline(
            TARGET_REPO="openshift-online/rosa-boundary",
            TARGET_PERIODIC_JOB=boundary_job, JOB_NAME=boundary_job,
        )
        self.run_step("publish")
        writes = [event for event in self.events() if event["tool"] == "gh" and event["action"] == "write"]
        self.assertEqual(writes[0]["args"][:2], ["pr", "create"])

    def test_rehearsal_preserves_partial_failure_without_writes(self):
        self.pipeline(MOCK_OPENWIKI_STATUS="7")
        self.run_step("publish", expected=7, JOB_NAME="rehearse-789-" + JOB)
        self.assert_no_publication()

    def test_production_updates_target_pr_not_same_named_fork(self):
        self.pipeline(MOCK_PRS=self.prs((88, "fork/rosa-cora-agent"), (42, REPO)), MOCK_EXPECT_EXISTING="1")
        self.run_step("publish")
        writes = [event for event in self.events() if event["tool"] == "gh" and event["action"] == "write"]
        self.assertIn("repos/" + REPO + "/pulls/42", writes[0]["args"])
        pushes = [event for event in self.events() if event.get("command") == "push"]
        self.assertTrue(any(arg.startswith("--force-with-lease=refs/heads/openwiki/update:") for arg in pushes[0]["args"]))
        self.assertIn("Prior completed page", self.git("-C", str(self.remote), "show", "openwiki/update:openwiki/prior.md"))

    def test_unexpected_jobs_fail_before_token_creation(self):
        self.patch()
        for job in ("other-" + JOB, JOB + "-extra", ""):
            with self.subTest(job=job):
                self.run_step("publish", expected=1, JOB_NAME=job)
        self.assertFalse(any(event["tool"] == "curl" for event in self.events()))

    def test_update_branch_cannot_be_base(self):
        for step in ("prepare", "update", "publish"):
            with self.subTest(step=step):
                self.run_step(step, expected=1, TARGET_UPDATE_BRANCH="main")
        self.assertFalse(any(event["tool"] == "curl" for event in self.events()))

    def test_outside_openwiki_patch_is_rejected(self):
        self.patch(path="source.txt", content="Must not publish\n")
        result = self.run_step("publish", expected=1)
        self.assertIn("Refusing unexpected OpenWiki patch path", result.stderr)
        self.assert_no_publication()

    def test_non_markdown_trailing_whitespace_is_rejected(self):
        self.patch(path="openwiki/claims.json", content='{"claims":[]} \n')
        result = self.run_step("publish", expected=None)
        self.assertNotEqual(result.returncode, 0)
        self.assertIn("trailing whitespace", result.stdout)
        self.assert_no_publication()

    def test_new_pr_race_prevents_stale_branch_replacement(self):
        self.patch()
        result = self.run_step(
            "publish", expected=1, MOCK_PR_CHANGE_AT="2",
            MOCK_PRS_AFTER=self.prs((42, REPO)),
        )
        self.assertIn("PR changed during this run", result.stderr)
        self.assert_no_publication()

    def test_pr_appearing_before_publish_first_lookup_is_not_taken_over(self):
        self.pipeline()
        result = self.run_step("publish", expected=1, MOCK_PRS=self.prs((42, REPO)))
        self.assertIn("PR changed since preparation", result.stderr)
        self.assert_no_publication()

    def test_prepared_pr_closing_or_replaced_during_generation_is_rejected(self):
        self.pipeline(MOCK_PRS=self.prs((42, REPO)), MOCK_EXPECT_EXISTING="1")
        for prs in ("[]", self.prs((43, REPO))):
            with self.subTest(prs=prs):
                self.clear_events()
                result = self.run_step("publish", expected=1, MOCK_PRS=prs)
                self.assertIn("PR changed since preparation", result.stderr)
                self.assert_no_publication()

    def test_existing_pr_closing_before_push_is_rejected(self):
        self.pipeline(MOCK_PRS=self.prs((42, REPO)), MOCK_EXPECT_EXISTING="1")
        result = self.run_step(
            "publish", expected=1, MOCK_PR_CHANGE_AT="2", MOCK_PRS_AFTER="[]",
        )
        self.assertIn("PR changed during this run", result.stderr)
        self.assert_no_publication()

    def test_existing_pr_lease_rejects_branch_deletion_or_rewind(self):
        self.pipeline(MOCK_PRS=self.prs((42, REPO)), MOCK_EXPECT_EXISTING="1")
        original = self.git("-C", str(self.remote), "rev-parse", "openwiki/update")
        for race in ("delete", "rewind"):
            with self.subTest(race=race):
                self.git("-C", str(self.remote), "update-ref", "refs/heads/openwiki/update", original)
                self.clear_events()
                self.run_step("publish", expected=1, MOCK_BRANCH_RACE=race)
                if race == "delete":
                    self.assertNotIn("refs/heads/openwiki/update", self.git("-C", str(self.remote), "show-ref"))
                else:
                    self.assertEqual(
                        self.git("-C", str(self.remote), "rev-parse", "openwiki/update"),
                        self.env["MOCK_FIRST_SHA"],
                    )
                self.assertFalse(any(
                    event["tool"] == "gh" and event["action"] == "write" for event in self.events()
                ))

    def test_stale_branch_lease_rejects_concurrent_push(self):
        self.patch()
        self.run_step("publish", expected=1, MOCK_BRANCH_RACE="advance")
        self.assertEqual(
            self.git("-C", str(self.remote), "rev-parse", "openwiki/update"),
            self.env["MOCK_MAIN_SHA"],
        )
        self.assertFalse(any(event["tool"] == "gh" and event["action"] == "write" for event in self.events()))

    def test_empty_patch_preserves_failure_without_authentication(self):
        (self.shared / "openwiki-docs.patch").write_text("")
        (self.shared / "openwiki-exit-status").write_text("9\n")
        self.run_step("publish", expected=9)
        self.assertFalse(any(event["tool"] == "curl" for event in self.events()))


if __name__ == "__main__":
    unittest.main()
