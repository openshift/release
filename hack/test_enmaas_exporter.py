#!/usr/bin/env python3

import ast
import json
from pathlib import Path
import re
import shutil
import subprocess
import sys
import unittest

import yaml

import test_enmaas_exporter_cli as exporter_cli
from test_enmaas_placement import EnmaasPlacementFixture, DEPLOY, DECODER
from test_enmaas_shell import write_stub


DIGEST = "sha256:" + "a" * 64
IMAGE = "image-registry.openshift-image-registry.svc:5000/enmaas/usage-exporter@" + DIGEST
STUB = r'''
import json
import io
import os
from pathlib import Path
import signal
import subprocess
import sys
import tarfile
import time

import yaml

args = sys.argv[1:]
root = Path(os.environ["FIXTURE"])
scenario = os.environ.get("SCENARIO", "normal")
command = Path(sys.argv[0]).stem
with (root / "calls").open("a") as stream:
    stream.write(json.dumps([command, args]) + "\n")
if command == "git":
    assert not any(name.startswith("GIT_TRACE") or name == "GIT_CURL_VERBOSE" for name in os.environ)
    if "clone" in args:
        assert "credential.helper=" in args and "credential.useHttpPath=true" in args
        helper = next(value for value in args if value.startswith("credential.https://"))
        assert helper.startswith("credential.https://github.com/redhat-et/enmaas-usage-exporter.git.helper=")
        assert 'cat "' + str(root / "credential") + '"' in helper
        assert "synthetic-ci-credential" not in helper
        assert args[-2] == "https://github.com/redhat-et/enmaas-usage-exporter.git"
        assert "--no-recurse-submodules" in args
        if scenario == "clone-error":
            print("UNSAFE_SOURCE_OUTPUT", file=sys.stderr)
            sys.exit(7)
        status = subprocess.run([os.environ["REAL_GIT"], "clone", "--no-hardlinks", str(root / "repository"), args[-1]],
                                stdout=subprocess.DEVNULL, stderr=subprocess.DEVNULL, check=False).returncode
        Path(args[-1], "untracked-credential").write_text("synthetic-ci-credential")
        assert "synthetic-ci-credential" not in Path(args[-1], ".git", "config").read_text()
        with (root / "directories").open("a") as stream:
            stream.write(str(Path(args[-1]).parent) + "\n")
        sys.exit(status)
    if "archive" in args and scenario.startswith("unsafe-tar-"):
        with tarfile.open(fileobj=sys.stdout.buffer, mode="w|") as archive:
            for filename, contents in (("Containerfile", b"FROM scratch\n"), ("app.txt", b"synthetic\n")):
                member = tarfile.TarInfo(filename)
                member.size = len(contents)
                archive.addfile(member, io.BytesIO(contents))
            filenames = {"unsafe-tar-parent": "../escaped", "unsafe-tar-absolute": str(root / "absolute-escape"),
                         "unsafe-tar-git": ".git/config", "unsafe-tar-newline": "new\nline", "unsafe-tar-hardlink": "hardlink"}
            filename = filenames.get(scenario, "escape")
            member = tarfile.TarInfo(filename)
            if scenario == "unsafe-tar-hardlink":
                member.type = tarfile.LNKTYPE
                member.linkname = "app.txt"
                archive.addfile(member)
            elif scenario == "unsafe-tar-link-child":
                member.type = tarfile.SYMTYPE
                member.linkname = str(root / "external")
                archive.addfile(member)
                member = tarfile.TarInfo("escape/child")
                member.size = 9
                archive.addfile(member, io.BytesIO(b"synthetic"))
            else:
                member.size = 9
                archive.addfile(member, io.BytesIO(b"synthetic"))
        sys.exit(0)
    sys.exit(subprocess.run([os.environ["REAL_GIT"], *args], check=False).returncode)
if command == "make":
    project = "enmaas-monitoring" if "PROJECT=enmaas-monitoring" in args else "enmaas"
    sys.stdout.write((root / (project + "-input.yaml")).read_text())
    sys.exit(0)
assert command == "oc"
if scenario == "real-cli" and ("start-build" in args or "get" in args):
    result = subprocess.run([os.environ["REAL_OC"], "--kubeconfig=/dev/null", "--server=" + os.environ["EXPORTER_CLI_SERVER"],
                             "--cache-dir=" + str(root / "cache"), *args], check=False, timeout=15)
    if not result.returncode:
        (root / "cli-wait-complete").touch()
    sys.exit(result.returncode)
if any(value.startswith("--kubeconfig=") for value in args):
    status = subprocess.run([os.environ["REAL_OC"], *args], check=False).returncode
    if not status:
        with (root / "decodes").open("a") as stream:
            stream.write(next(value.split("=", 1)[1] for value in args if value.startswith("--filename=")) + "\n")
    sys.exit(status)
if args[:2] == ["get", "nodes"]:
    print((root / "input-nodes.json").read_text())
    sys.exit(0)
if args[0] == "apply":
    assert len(set((root / "decodes").read_text().splitlines())) == 2
    with (root / "applies").open("a") as stream:
        stream.write(args[-1] + "\n")
    sys.exit(0)
assert "--loglevel=0" in args and any(value.startswith("--request-timeout=") for value in args)
args = args[args.index("enmaas") + 1:]
if args[0] == "apply":
    resources = yaml.safe_load(sys.stdin)["items"]
    assert [item["kind"] for item in resources] == ["ImageStream", "BuildConfig"]
    assert all(item["metadata"] == {"name": "usage-exporter", "namespace": "enmaas"} for item in resources)
    spec = resources[1]["spec"]
    assert spec["source"] == {"type": "Binary"} and spec["triggers"] == []
    assert spec["strategy"] == {"type": "Docker", "dockerStrategy": {"dockerfilePath": "Containerfile"}}
    assert spec["completionDeadlineSeconds"] == 900
    assert spec["output"] == {"to": {"kind": "ImageStreamTag", "name": "usage-exporter:latest"}}
    if scenario == "configure-error":
        sys.exit(7)
elif args[0] == "start-build":
    assert args[1] == "usage-exporter" and "--follow=false" in args and "--wait" in args
    assert args[args.index("-o") + 1] == "name" and "--request-timeout=900s" in args
    context = Path(next(value.split("=", 1)[1] for value in args if value.startswith("--from-dir=")))
    assert context.stat().st_mode & 0o777 == 0o700
    assert not (context / ".git").exists() and not (context / "untracked-credential").exists()
    expected = ["Containerfile", "app.txt", "app-link", "run.sh"] if scenario == "safe-links" else ["Containerfile", "app.txt"]
    assert sorted(path.name for path in context.iterdir()) == sorted(expected)
    assert all(b"synthetic-ci-credential" not in path.read_bytes() for path in context.iterdir() if path.is_file())
    if scenario == "safe-links":
        assert (context / "app-link").is_symlink() and (context / "app-link").resolve() == context / "app.txt"
        assert (context / "run.sh").stat().st_mode & 0o111
    if scenario in ("start-error", "failed", "cancelled", "build-error"):
        print("UNSAFE_SOURCE_OUTPUT", file=sys.stderr)
        sys.exit(8)
    if scenario == "terminated":
        os.kill(int(os.environ["EXPORTER_HELPER_PID"]), signal.SIGTERM)
        os.killpg(os.getpgrp(), signal.SIGTERM)
    if scenario == "timeout":
        time.sleep(5)
    if scenario in ("oversized-start", "flood-start"):
        sys.stdout.write("x" * 100000)
        if scenario == "flood-start":
            time.sleep(5)
        sys.exit(0)
    if scenario == "nul-start":
        sys.stdout.write("build.build.openshift.io/usage-exporter-7\0\n")
        sys.exit(0)
    (root / "cli-wait-complete").touch()
    print("invalid-build-response" if scenario == "bad-start" else "build.build.openshift.io/usage-exporter-7")
elif args[:2] == ["get", "build"]:
    assert args[2] == "usage-exporter-7"
    assert (root / "cli-wait-complete").exists()
    phase = "Running" if scenario == "incomplete-after-wait" else "Complete"
    if scenario == "query-error":
        sys.exit(17)
    count = root / "polls"
    number = int(count.read_text()) + 1 if count.exists() else 1
    count.write_text(str(number))
    digest = "sha256:" + "a" * 64
    if scenario == "malformed-digest":
        digest = "sha256:invalid"
    if scenario == "changed-digest" and number % 2 == 0:
        digest = "sha256:" + "b" * 64
    status = {"phase": phase, "config": {"name": "usage-exporter"},
              "output": {"to": {"imageDigest": digest}},
              "outputDockerImageReference": "image-registry.openshift-image-registry.svc:5000/enmaas/usage-exporter:latest"}
    if scenario == "absent-digest":
        del status["output"]
    if scenario == "wrong-output":
        status["outputDockerImageReference"] = "example.invalid/other:latest"
    if scenario == "bad-build":
        print("UNSAFE_SOURCE_OUTPUT")
        sys.exit(0)
    if scenario == "oversized-build":
        print("x" * 100000)
        sys.exit(0)
    document = {"metadata": {"name": "usage-exporter-6" if scenario == "wrong-build" else args[2], "namespace": "enmaas",
                             "uid": "old-build-uid" if scenario == "stale-build" and number % 2 == 0 else "new-build-uid"},
                "spec": {"output": {"to": {"kind": "ImageStreamTag", "name": "usage-exporter:latest"}}}, "status": status}
    print(json.dumps(document))
    if scenario == "multi-build":
        print(json.dumps(document))
elif args[:2] == ["get", "imagestreamimage"]:
    assert args[2] == "usage-exporter@sha256:" + "a" * 64
    if scenario == "unpublished":
        sys.exit(18)
    if scenario == "multi-image":
        print(json.dumps({"image": {"metadata": {"name": "sha256:" + "b" * 64}}}))
    print(json.dumps({"image": {"metadata": {"name": "sha256:" + ("b" if scenario == "stale-image" else "a") * 64}}}))
elif args[:2] == ["auth", "can-i"]:
    assert "imagestreams.image.openshift.io/usage-exporter" in args
    assert "--subresource=layers" in args
    assert "--as-group=system:serviceaccounts:enmaas" in args
    if scenario == "denied":
        print("no")
        sys.exit(1)
    print("yes")
elif args[:2] == ["get", "serviceaccount"]:
    if scenario == "sa-error":
        sys.exit(19)
    (root / "account").write_text(args[2])
    print(json.dumps({"metadata": {"name": args[2], "uid": "sa-uid", "annotations": {
        "openshift.io/internal-registry-pull-secret-ref": "managed-registry"}},
        "imagePullSecrets": [] if scenario == "unlinked" else [{"name": "managed-registry"}]}))
elif args[:2] == ["get", "secret"]:
    assert args[2] == "managed-registry" and "--ignore-not-found=true" in args
    assert args[-1].startswith("go-template=") and '}}ready{{' in args[-1]
    if scenario == "secret-error":
        print("UNSAFE_SOURCE_OUTPUT", file=sys.stderr)
        sys.exit(20)
    if scenario != "missing-secret":
        print("kubernetes.io/dockercfg\n" + ("foreign" if scenario == "wrong-owner" else (root / "account").read_text()) + "\nsa-uid\n" +
              ("" if scenario == "empty-secret" else "ready"))
else:
    sys.exit(99)
'''


class EnmaasExporterTests(EnmaasPlacementFixture):
    def workload(self, kind, spec):
        resource = super().workload(kind, spec)
        resource["metadata"]["namespace"] = "enmaas"
        return resource

    def setUp(self):
        super().setUp()
        self.bin = self.directory / "bin"
        self.bin.mkdir()
        self.git = shutil.which("git")
        self.assertIsNotNone(self.git, "real git is required for binary archive regressions")
        self.repository = self.directory / "repository"
        self.repository.mkdir()
        for args in (("init",), ("config", "user.email", "ci@example.invalid"), ("config", "user.name", "Synthetic CI")):
            subprocess.run([self.git, "-C", str(self.repository), *args], check=True, capture_output=True)
        (self.repository / "Containerfile").write_text("FROM scratch\nCOPY app.txt /app.txt\n")
        (self.repository / "app.txt").write_text("synthetic public fixture\n")
        subprocess.run([self.git, "-C", str(self.repository), "add", "."], check=True, capture_output=True)
        subprocess.run([self.git, "-C", str(self.repository), "-c", "commit.gpgsign=false", "commit", "-m", "fixture"],
                       check=True, capture_output=True)
        self.credential = self.directory / "credential"
        self.credential.write_text("synthetic-ci-credential")
        self.credential.chmod(0o600)
        for command in ("git", "oc", "make"):
            write_stub(self.bin / command, STUB)
        self.environment = {"PATH": str(self.bin) + ":/usr/local/bin:/usr/bin:/bin", "HOME": str(self.directory),
                            "FIXTURE": str(self.directory), "WORK_DIR": str(self.directory),
                            "SHARED_DIR": str(self.directory / "shared"), "ARTIFACT_DIR": str(self.directory / "artifacts"),
                            "REAL_GIT": str(Path(self.git).resolve()), "REAL_OC": DECODER,
                            "TEST_PYTHON": sys.executable, "ENMAAS_ENV": "synthetic"}
        for name in ("shared", "artifacts"):
            (self.directory / name).mkdir()
        source = DEPLOY.read_text()
        self.build = "build_exporter() (" + source.split("build_exporter() (", 1)[1].split("\n)\n", 1)[0] + "\n)\n"
        self.build = self.build.replace("/secret/enmaas/token", '"' + str(self.credential) + '"')
        self.assertNotIn("python", self.build.lower())
        self.assertIn('exporter_run 900s "${command[@]}" start-build', self.build)
        self.build = self.build.replace('exporter_run 900s "${command[@]}" start-build',
                                        'exporter_run "$EXPORTER_TEST_TIMEOUT" "${command[@]}" start-build')
        self.build = self.build.replace('stage="binary build wait"',
                                        'stage="binary build wait"; export EXPORTER_HELPER_PID=$BASHPID')
        clock = "\nclock = iter(range(0, 100000, 10))\ntime.monotonic = lambda: next(clock)\ntime.sleep = lambda seconds: None\n"
        self.script = self.script.replace("import time\n", "import time\n" + clock)

    def _calls(self):
        path = self.directory / "calls"
        return [json.loads(line) for line in path.read_text().splitlines()] if path.exists() else []

    def _run_script(self, script, scenario="normal"):
        result = subprocess.run(["bash", "-euxv", "-o", "pipefail", "-c", script],
                                cwd=self.directory, env={**self.environment, "SCENARIO": scenario,
                                                         "EXPORTER_TEST_TIMEOUT": "0.5s" if scenario in ("timeout", "flood-start") else "10s"},
                                capture_output=True, text=True, check=False, timeout=45, start_new_session=True)
        self.assertFalse("UNSAFE_SOURCE_OUTPUT" in result.stdout + result.stderr, "private command output escaped")
        self.assertFalse("synthetic-ci-credential" in result.stdout + result.stderr, "credential escaped")
        directories = self.directory / "directories"
        if directories.exists():
            self.assertTrue(all(not Path(path).exists() for path in directories.read_text().splitlines()), "source files retained")
        self.assertEqual(list((self.directory / "artifacts").iterdir()), [])
        self.assertEqual(list((self.directory / "shared").iterdir()), [])
        return result

    def test_binary_build_uses_completed_build_digest_and_only_tracked_context(self):
        self.environment.update(GIT_TRACE_CURL=str(self.directory / "artifacts/trace"), GIT_TRACE_REDACT="0",
                                TAR_OPTIONS="--verbose --absolute-names")
        result = self._run_script(self.build + "build_exporter\necho AFTER_BUILD\n", "pending")
        self.assertEqual(result.returncode, 0, result.stderr)
        self.assertIn(IMAGE, result.stdout)
        self.assertEqual(result.stdout, IMAGE + "\nAFTER_BUILD\n")
        calls = self._calls()
        self.assertEqual(sum("start-build" in args for _, args in calls), 1)
        self.assertEqual(sum("build" in args for _, args in calls), 2)
        self.assertFalse(any("istag" in args for _, args in calls))

    def test_missing_mounted_credential_fails_before_clone(self):
        self.credential.unlink()
        result = self._run_script(self.build + "build_exporter\necho AFTER_BUILD\n")
        self.assertNotEqual(result.returncode, 0)
        self.assertNotIn("AFTER_BUILD", result.stdout)
        self.assertEqual(self._calls(), [])

    def test_context_preserves_safe_symlinks_and_executable_files(self):
        (self.repository / "app-link").symlink_to("app.txt")
        (self.repository / "run.sh").write_text("#!/bin/sh\nexit 0\n")
        (self.repository / "run.sh").chmod(0o755)
        subprocess.run([self.git, "-C", str(self.repository), "add", "."], check=True, capture_output=True)
        subprocess.run([self.git, "-C", str(self.repository), "-c", "commit.gpgsign=false", "commit", "-m", "safe fixture"],
                       check=True, capture_output=True)
        result = self._run_script(self.build + "build_exporter\n", "safe-links")
        self.assertEqual(result.returncode, 0, result.stderr)

    def test_context_rejects_escaping_symlinks_and_archive_paths(self):
        for target in ("../../credential", "/absolute-escape"):
            with self.subTest(target=target):
                link = self.repository / "escape"
                link.unlink(missing_ok=True)
                link.symlink_to(target)
                subprocess.run([self.git, "-C", str(self.repository), "add", "."], check=True, capture_output=True)
                subprocess.run([self.git, "-C", str(self.repository), "-c", "commit.gpgsign=false", "commit", "-m", "unsafe fixture"],
                               check=True, capture_output=True)
                result = self._run_script(self.build + "build_exporter\n")
                self.assertNotEqual(result.returncode, 0)
                self.assertFalse(any("start-build" in args for _, args in self._calls()))
        (self.directory / "external").mkdir()
        for scenario in ("unsafe-tar-parent", "unsafe-tar-absolute", "unsafe-tar-git", "unsafe-tar-newline",
                         "unsafe-tar-hardlink", "unsafe-tar-link-child"):
            with self.subTest(scenario=scenario):
                result = self._run_script(self.build + "build_exporter\n", scenario)
                self.assertNotEqual(result.returncode, 0)
                self.assertFalse(any("start-build" in args for _, args in self._calls()))
                self.assertFalse((self.directory / "absolute-escape").exists())
                self.assertEqual(list((self.directory / "external").iterdir()), [])

    def test_clone_helper_reads_current_file_only_for_matching_host_and_repository(self):
        helper = re.search(r"-c '(credential\.https://[^\n]+)'", self.build).group(1)
        environment = {"PATH": "/usr/local/bin:/usr/bin:/bin", "HOME": str(self.directory),
                       "GIT_TERMINAL_PROMPT": "0", "GIT_CONFIG_NOSYSTEM": "1"}
        arguments = [self.git, "-c", "credential.helper=", "-c", "credential.useHttpPath=true", "-c", helper,
                     "credential", "fill"]
        for value in ("synthetic-first", "synthetic-second"):
            self.credential.write_text(value)
            result = subprocess.run(arguments, input="protocol=https\nhost=github.com\npath=redhat-et/enmaas-usage-exporter.git\n\n",
                                    env=environment, capture_output=True, text=True, check=False, timeout=10)
            self.assertEqual(result.returncode, 0)
            self.assertTrue("password=" + value in result.stdout, "helper did not read current mounted-file content")
        for host, path in (("github.com", "other/repository.git"), ("example.invalid", "redhat-et/enmaas-usage-exporter.git")):
            result = subprocess.run(arguments, input=f"protocol=https\nhost={host}\npath={path}\n\n", env=environment,
                                    capture_output=True, text=True, check=False, timeout=10)
            self.assertNotEqual(result.returncode, 0)
            self.assertFalse("password=" in result.stdout, "helper escaped host/repository scope")
        self.assertFalse((self.directory / ".gitconfig").exists())

    def test_build_failures_never_continue_or_resolve_stale_tags(self):
        for scenario in ("clone-error", "configure-error", "start-error", "failed", "cancelled", "build-error",
                         "query-error", "timeout", "absent-digest", "malformed-digest", "stale-build", "wrong-build",
                         "wrong-output", "unpublished", "stale-image", "incomplete-after-wait", "bad-start",
                         "bad-build", "oversized-start", "changed-digest", "nul-start", "oversized-build", "flood-start",
                         "multi-build", "multi-image"):
            with self.subTest(scenario=scenario):
                (self.directory / "calls").unlink(missing_ok=True)
                (self.directory / "polls").unlink(missing_ok=True)
                (self.directory / "cli-wait-complete").unlink(missing_ok=True)
                result = self._run_script(self.build + "build_exporter\necho AFTER_BUILD\n", scenario)
                self.assertNotEqual(result.returncode, 0)
                self.assertNotIn("AFTER_BUILD", result.stdout)
                self.assertIn("ERROR: Exporter image build failed during", result.stderr)
                self.assertLessEqual(sum("start-build" in args for _, args in self._calls()), 1)
                if scenario == "timeout":
                    self.assertIn("(timeout)", result.stderr)
                elif scenario in ("start-error", "failed", "cancelled", "build-error"):
                    self.assertIn("command exit 8", result.stderr)
                elif scenario in ("bad-start", "bad-build", "oversized-start"):
                    self.assertIn("invalid response", result.stderr)

    def test_termination_cleans_context_without_leaking_output(self):
        result = self._run_script(self.build + "build_exporter\necho AFTER_BUILD\n", "terminated")
        self.assertNotEqual(result.returncode, 0)
        self.assertNotIn("AFTER_BUILD", result.stdout)
        self.assertIn("interrupted", result.stderr)

    def test_utility_and_conditional_failures_stop_build(self):
        write_stub(self.bin / "tar", 'import sys\nprint("UNSAFE_SOURCE_OUTPUT", file=sys.stderr)\nsys.exit(18)\n')
        result = self._run_script(self.build + "build_exporter\necho AFTER_BUILD\n")
        self.assertNotEqual(result.returncode, 0)
        self.assertNotIn("AFTER_BUILD", result.stdout)
        self.assertFalse(any("start-build" in args for _, args in self._calls()))
        (self.bin / "tar").unlink()
        for invocation in ("build_exporter", "image=$(build_exporter)"):
            for scenario in ("clone-error", "configure-error", "start-error", "query-error", "absent-digest",
                             "unpublished", "timeout", "bad-start", "changed-digest", "multi-image"):
                with self.subTest(invocation=invocation, scenario=scenario):
                    for filename in ("calls", "polls", "cli-wait-complete"):
                        (self.directory / filename).unlink(missing_ok=True)
                    result = self._run_script(self.build + '\nif ' + invocation + '; then echo MASKED_SUCCESS; else exit 1; fi\n',
                                              scenario)
                    self.assertNotEqual(result.returncode, 0, "conditional invocation masked failure")
                    self.assertEqual(result.stdout, "")
                    self.assertIn("ERROR: Exporter image build failed during", result.stderr)
                    self.assertLessEqual(sum("start-build" in args for _, args in self._calls()), 1)
        self.credential.unlink()
        (self.directory / "calls").unlink(missing_ok=True)
        result = self._run_script(self.build + '\nif image=$(build_exporter); then echo MASKED_SUCCESS; else exit 1; fi\n')
        self.assertNotEqual(result.returncode, 0)
        self.assertEqual(self._calls(), [])

    def test_bash_helper_uses_real_cli_upload_and_native_wait(self):
        fixture = exporter_cli.EnmaasExporterCliTests()
        fixture.setUp()
        try:
            self.environment["EXPORTER_CLI_SERVER"] = "http://127.0.0.1:" + str(fixture.server.server_port)
            for scenario in ("complete", "failed", "watch", "ambiguous", "lookup-error", "wrong-output", "stale-image",
                             "changed-uid", "changed-digest", "incomplete", "timeout"):
                with self.subTest(scenario=scenario):
                    fixture.responses["scenario"] = scenario
                    fixture.responses["build_gets"] = 0
                    fixture.requests.clear()
                    script = self.build.replace('exporter_run "$EXPORTER_TEST_TIMEOUT"', 'exporter_run 1s') if scenario == "timeout" else self.build
                    result = self._run_script(script + "build_exporter\n", "real-cli")
                    if scenario not in ("complete", "watch"):
                        self.assertNotEqual(result.returncode, 0)
                        self.assertEqual(result.stdout, "")
                    else:
                        self.assertEqual(result.returncode, 0, result.stderr)
                        self.assertEqual(result.stdout, IMAGE + "\n")
                    self.assertEqual(sum(method == "POST" and path.endswith("/instantiatebinary")
                                         for method, path, _ in fixture.requests), 1)
                    self.assertFalse(any(path.endswith("/log") for _, path, _ in fixture.requests))
                    self.assertFalse(any("/imagestreamtags/" in path for _, path, _ in fixture.requests))
                    self.assertEqual(sorted(fixture.uploads[-1]), ["Containerfile", "app.txt"])
        finally:
            fixture.doCleanups()

    def _setup_manifests(self, missing=False):
        spec = self.pod_spec()
        spec["containers"].extend([{"name": "praxis", "image": "example.invalid/praxis:default"},
                                    {"name": "usage-exporter", "image": "quay.io/modden/enmaas-usage-exporter:default"}])
        spec["initContainers"].append({"name": "exporter-init", "image": "quay.io/modden/enmaas-usage-exporter@sha256:" + "b" * 64})
        if missing:
            spec["containers"].pop()
            spec["initContainers"].pop()
        spec["serviceAccountName"] = "default"
        spec["imagePullSecrets"] = [{"name": "external-preserved"}, {"name": "managed-registry"}]
        application = {"apiVersion": "v1", "kind": "List", "items": [self.workload("Deployment", spec)]}
        for project in ("enmaas", "enmaas-monitoring"):
            application["items"][0]["metadata"]["namespace"] = project
            (self.directory / (project + "-input.yaml")).write_text(yaml.safe_dump(application))
        (self.directory / "input-nodes.json").write_text(json.dumps({"items": self.nodes}))
        (self.directory / "nodes.json").write_text(json.dumps({"items": self.nodes}))
        return spec

    def normalize(self, scenario="normal", image=IMAGE, missing=False):
        before = self._setup_manifests(missing)
        manifest = self.directory / "enmaas-input.yaml"
        script = self.script.split('\nconfigure_placement "$1"', 1)[0]
        result = self._run_script(script + '\nconfigure_placement "' + str(manifest) + '" enmaas false "' + image + '"\n', scenario)
        after = yaml.safe_load(manifest.read_text())["items"][0]["spec"]["template"]["spec"]
        return result, before, after

    def test_only_matching_regular_and_init_exporter_images_change(self):
        result, before, after = self.normalize()
        self.assertEqual(result.returncode, 0, result.stderr)
        self.assertEqual(after["containers"][:-1], before["containers"][:-1])
        self.assertEqual(after["containers"][-1]["image"], IMAGE)
        self.assertEqual(after["initContainers"][-1]["image"], IMAGE)
        self.assertEqual(after["initContainers"][:-1], before["initContainers"][:-1])
        for field in ("imagePullSecrets", "serviceAccountName", "volumes"):
            self.assertEqual(after[field], before[field])

    def test_missing_exporter_and_invalid_digest_fail_closed(self):
        for image, missing in ((IMAGE, True), ("example.invalid/exporter:latest", False)):
            with self.subTest(image=image, missing=missing):
                result, before, after = self.normalize(image=image, missing=missing)
                self.assertNotEqual(result.returncode, 0)
                self.assertEqual(before, after)

    def test_pull_errors_and_unready_credentials_fail_without_secret_leaks(self):
        for scenario in ("denied", "sa-error", "unlinked", "secret-error", "missing-secret", "wrong-owner", "empty-secret"):
            with self.subTest(scenario=scenario):
                result, before, after = self.normalize(scenario)
                self.assertNotEqual(result.returncode, 0)
                self.assertIn("Exporter pull setup failed", result.stderr)
                self.assertEqual(before, after)

    def test_explicit_pull_refs_must_include_managed_reference(self):
        self._setup_manifests()
        manifest = self.directory / "enmaas-input.yaml"
        data = yaml.safe_load(manifest.read_text())
        data["items"][0]["spec"]["template"]["spec"]["imagePullSecrets"] = [{"name": "external-preserved"}]
        manifest.write_text(yaml.safe_dump(data))
        script = self.script.split('\nconfigure_placement "$1"', 1)[0]
        result = self._run_script(script + '\nconfigure_placement "' + str(manifest) + '" enmaas false "' + IMAGE + '"\n')
        self.assertNotEqual(result.returncode, 0)
        self.assertEqual(yaml.safe_load(manifest.read_text()), data)

    def test_actual_local_client_projects_only_secret_readiness_metadata(self):
        source = self.script.split("<<'PYTHON'\n", 1)[1].split("\nPYTHON", 1)[0]
        template = next(ast.literal_eval(node.value) for node in ast.walk(ast.parse(source))
                        if isinstance(node, ast.Assign) and any(isinstance(target, ast.Name)
                                                                and target.id == "template" for target in node.targets))
        secret = {"apiVersion": "v1", "kind": "Secret", "type": "kubernetes.io/dockercfg",
                  "metadata": {"name": "managed-registry", "namespace": "enmaas", "annotations": {
                      "openshift.io/internal-registry-auth-token.service-account": "default"},
                      "ownerReferences": [{"apiVersion": "v1", "kind": "ServiceAccount", "name": "default", "uid": "sa-uid"}]},
                  "data": {".dockercfg": "e30="}}
        result = subprocess.run([DECODER, "--kubeconfig=/dev/null", "--server=http://127.0.0.1:1", "label",
                                 "--local=true", "-f", "-", "ci=offline", "-o", "go-template=" + template],
                                input=json.dumps(secret), capture_output=True, text=True, check=False, timeout=15)
        self.assertEqual(result.returncode, 0)
        self.assertTrue(result.stdout.splitlines() == ["kubernetes.io/dockercfg", "default", "sa-uid", "ready"],
                        "local client must emit only four readiness fields, never Secret data")

    def test_exporter_missing_or_foreign_namespace_fails_before_pull_queries(self):
        for namespace in (None, "other"):
            with self.subTest(namespace=namespace):
                self._setup_manifests()
                manifest = self.directory / "enmaas-input.yaml"
                data = yaml.safe_load(manifest.read_text())
                if namespace is None:
                    del data["items"][0]["metadata"]["namespace"]
                else:
                    data["items"][0]["metadata"]["namespace"] = namespace
                manifest.write_text(yaml.safe_dump(data))
                (self.directory / "calls").unlink(missing_ok=True)
                script = self.script.split('\nconfigure_placement "$1"', 1)[0]
                result = self._run_script(script + '\nconfigure_placement "' + str(manifest) + '" enmaas false "' + IMAGE + '"\n')
                self.assertNotEqual(result.returncode, 0)
                self.assertEqual(self._calls(), [])
                self.assertEqual(yaml.safe_load(manifest.read_text()), data)

    def test_default_and_custom_sa_inheritance_preserves_unrelated_refs(self):
        for account in ("default", "custom"):
            for kind in ("Pod", "CronJob", "Deployment", "DeploymentConfig"):
                with self.subTest(account=account, kind=kind):
                    spec = self.pod_spec()
                    spec["containers"].append({"name": "exporter", "image": "quay.io/modden/enmaas-usage-exporter:default"})
                    spec["serviceAccountName"] = account
                    document = {"apiVersion": "v1", "kind": "List", "items": [self.workload(kind, spec)]}
                    (self.directory / "nodes.json").write_text(json.dumps({"items": self.nodes}))
                    manifest = self.directory / "nested.yaml"
                    manifest.write_text(yaml.safe_dump(document))
                    script = self.script.split('\nconfigure_placement "$1"', 1)[0]
                    result = self._run_script(script + '\nconfigure_placement "' + str(manifest) + '" enmaas false "' + IMAGE + '"\n')
                    self.assertEqual(result.returncode, 0, result.stderr)
                    actual = next(self.find_specs(yaml.safe_load(manifest.read_text())))
                    self.assertNotIn("imagePullSecrets", actual)
                    self.assertEqual(actual["serviceAccountName"], account)
                    self.assertEqual(actual["containers"][-1]["image"], IMAGE)

    def test_actual_consumer_build_normalize_both_decode_before_workload_apply(self):
        consumer = DEPLOY.read_text().split('EXPORTER_IMAGE=$(build_exporter)\n', 1)[1].split('echo "Patching NetworkPolicy', 1)[0]
        consumer = consumer.replace("/tmp/", str(self.directory) + "/")
        normalizer = self.script.split('\nconfigure_placement "$1"', 1)[0]
        for scenario in ("normal", "failed", "absent-digest", "denied", "missing-secret", "missing-exporter"):
            with self.subTest(scenario=scenario):
                self._setup_manifests(missing=scenario == "missing-exporter")
                for name in ("decodes", "applies"):
                    (self.directory / name).unlink(missing_ok=True)
                result = self._run_script(self.build + normalizer + '\nEXPORTER_IMAGE=$(build_exporter)\n' + consumer, scenario)
                if scenario != "normal":
                    self.assertNotEqual(result.returncode, 0)
                    self.assertFalse((self.directory / "applies").exists())
                    continue
                self.assertEqual(result.returncode, 0, result.stderr)
                self.assertEqual(len((self.directory / "applies").read_text().splitlines()), 2)
                rendered = yaml.safe_load((self.directory / "enmaas.yaml").read_text())
                self.assertEqual(rendered["items"][0]["spec"]["template"]["spec"]["containers"][-1]["image"], IMAGE)
                monitoring = yaml.safe_load((self.directory / "enmaas-monitoring.yaml").read_text())
                self.assertNotEqual(monitoring["items"][0]["spec"]["template"]["spec"]["containers"][-1]["image"], IMAGE)


if __name__ == "__main__":
    unittest.main()
