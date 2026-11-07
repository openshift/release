#!/usr/bin/env python3
"""Offline fixtures for the delivered step: python3 hack/test_rosa_ocm_fvt_artifacts.py.

The prepare ref's command installs itself into SHARED_DIR before the wrapper runs.
Only those two delivered commands are copied, with no repository checkout at runtime.
Metadata describes the outer collector identity, not the nested image's identity.
Scans stop at 128 entries, 16 result locations and 32 reports per location; labels
omit result names and phase timestamps. Report contents are never read by collection.
"""

import errno
import json
import os
from pathlib import Path
import shutil
import stat
import subprocess
import sys
import tarfile
import tempfile
import unittest

import yaml


REPOSITORY = Path(__file__).resolve().parents[1]
STEP = REPOSITORY / "ci-operator/step-registry/rosa/e2e/ocm-fvt"
SECRET = "FIXTURE_SECRET_DO_NOT_PRINT"
DIGEST = "sha256:" + "a" * 64


def read_yaml(path):
    """Read repository YAML using the safe loader, with its faster variant if present."""
    return yaml.load(path.read_text(encoding="utf-8"),
                     Loader=getattr(yaml, "CSafeLoader", yaml.SafeLoader))


def delivery_registry(root, wrapper):
    """Resolve command symlinks rather than assuming only one ref executes the wrapper."""
    definitions = {kind: {} for kind in ("ref", "chain", "workflow")}
    consumers = set()
    for kind, entries in definitions.items():
        for path in root.rglob(f"*-{kind}.yaml"):
            entry = read_yaml(path)[kind]
            entries[entry["as"]] = entry
            if kind == "ref" and (path.parent / entry["commands"]).resolve() == wrapper.resolve():
                consumers.add(entry["as"])
    return definitions, consumers


def expand_delivery_steps(steps, chains, active=()):
    """Flatten nested chains in execution order, rejecting dependency cycles."""
    for step in steps or []:
        if "chain" in step:
            name = step["chain"]
            if name in active:
                raise ValueError("Cyclic step chain")
            yield from expand_delivery_steps(chains[name]["steps"], chains, (*active, name))
        else:
            yield step.get("ref", step.get("as"))


def missing_helper_delivery(configuration, definitions, consumers):
    """Check resolved workflow phases, including explicit phase overrides, for delivery."""
    for test in configuration.get("tests", []):
        steps = test.get("steps") or {}
        workflow = definitions["workflow"].get(steps.get("workflow"), {}).get("steps", {})
        for phase in ("pre", "test", "post"):
            sequence = steps.get(phase)
            if sequence is None:
                sequence = workflow.get(phase) or []
            expanded = list(expand_delivery_steps(sequence, definitions["chain"]))
            for index, name in enumerate(expanded):
                if name in consumers and (index == 0 or expanded[index - 1] != "rosa-e2e-ocm-fvt-prepare"):
                    yield test["as"], phase, name


def raw_output(base):
    return next(base.glob(".ocm-fvt-*/output"), base / "artifacts/ocm-fvt-results")


def mock_artifact_command(command, arguments, base, case):
    output = raw_output(base)
    if command == "oc":
        if case != "ready" or arguments[-3:] != ["get", "ns", "default"]:
            raise AssertionError("Unexpected fixture API probe")
        (base / "oc-called").touch()
        return 0
    if command == "find":
        if case == "find-failure" and arguments == [
                str(output), "-type", "f", "-name", "report.xml", "-print0"]:
            print(SECRET, file=sys.stderr)
            return 94
        os.execv("/usr/bin/find", ["find", *arguments])
    if command == "cp":
        if case == "copy-failure" and arguments[-1] == str(
                base / "artifacts/junit-ocm-fvt-report.xml"):
            print(SECRET, file=sys.stderr)
            return 91
        os.execv("/bin/cp", ["cp", *arguments])
    if command == "python3":
        helper = str(base / "shared/ocm-fvt-artifacts.py")
        if case == "publication-failure" and arguments == [
                helper, "publish", str(output), str(base / "artifacts")]:
            print(SECRET, file=sys.stderr)
            return 95
        if case == "collector-failure" and arguments == [
                helper, "metadata", str(output), str(base / "artifacts/ocm-fvt-artifact-metadata.json")]:
            return 92
        os.execv(sys.executable, [sys.executable, *arguments])
    raise AssertionError("Unexpected artifact fixture command")


def prepare_publication_case(base, case, output, result):
    """Build producer output for publication safety, bounds and lifecycle scenarios."""
    if case == "permissions":
        (result / "report.xml").chmod(0o444)
        result.chmod(0o555)
        try:
            descriptor, name = tempfile.mkstemp(prefix="tmp-censor", dir=result)
        except PermissionError:
            (base / "before-denied").touch()
        else:
            os.close(descriptor)
            Path(name).unlink()
            raise AssertionError("Read-only source unexpectedly permitted censor temporary file")
    elif case == "publication-safety":
        for name in (".datainfo", "diagnostics"):
            (output / name).mkdir()
        (output / ".datainfo/private").write_text(SECRET, encoding="utf-8")
        for name in ("cluster.ini", "kubeconfig", "guest.kubeconfig"):
            (result / name).write_text(SECRET, encoding="utf-8")
        (result / "linked").symlink_to(base / "outside/secret")
        (result / "linked-directory").symlink_to(base / "outside", target_is_directory=True)
        os.mkfifo(result / "fifo")
        for name in ("phase.json", "test-matrix.json", "report.html", "diagnostic.log",
                     "diagnostic.txt", "image.png", "gather.tar.gz", "unknown-diagnostic"):
            (output / "diagnostics" / name).write_bytes(b"fixture diagnostic\n")
    elif case == "publication-bound":
        with (result / "oversized.log").open("wb") as artifact:
            artifact.truncate(256 * 1024 * 1024 + 1)
    elif case == "publication-entry-bound":
        for index in range(8193):
            (result / f"entry-{index}").touch()
    elif case == "publication-depth-bound":
        directory = result
        for index in range(17):
            directory /= str(index)
            directory.mkdir()
    elif case == "ready":
        (output / ".datainfo").mkdir()
        (result / "cluster.ini").write_text(
            "ID=fixture-cluster\nState=ready\n", encoding="utf-8")
        (result / "guest.kubeconfig").write_text(
            "apiVersion: v1\nkind: Config\n", encoding="utf-8")


def mock_command(command, arguments):
    base = Path(os.environ["FIXTURE_DIR"])
    case = os.environ["FIXTURE_CASE"]
    output = raw_output(base)
    if command in ("cat", "env"):
        if ((command == "cat" and arguments[0].startswith("/usr/local/cs-qe-credentials/"))
                or (command == "env" and arguments[0] == "-i")):
            return 0
        os.execv("/usr/bin/" + command, [command, *arguments])
    if command in ("find", "cp", "python3", "oc"):
        return mock_artifact_command(command, arguments, base, case)
    if command != "podman":
        raise AssertionError("Unexpected fixture command")
    with (base / "calls.jsonl").open("a", encoding="utf-8") as calls:
        calls.write(json.dumps(arguments) + "\n")
    if arguments[0] == "pull":
        return 0
    if arguments[0] == "inspect":
        if case == "invalid-digest":
            print(SECRET)
        elif case != "inspect-failure":
            print("fixture@" + DIGEST)
        return 93 if case == "inspect-failure" else 0
    if arguments[0] != "run":
        raise AssertionError("Unexpected podman operation")
    if case == "missing":
        output.rmdir()
    elif case == "root-symlink":
        output.rmdir()
        output.symlink_to(base / "outside", target_is_directory=True)
    elif case == "root-unreadable":
        output.chmod(0)
    else:
        result = output / "test-result-fixture"
        result.mkdir(mode=0o755)
        (result / "report.xml").write_text("<testsuites/>\n", encoding="utf-8")
        (result / "pre-cluster-creation_123456.json").write_text(SECRET, encoding="utf-8")
        (result / "pre-cluster-creation_123456.json").chmod(0)
        if case in ("copy-failure", "find-failure"):
            (output / ".datainfo").mkdir()
            (result / "cluster.ini").write_text(
                "ID=fixture-cluster\nState=installing\n", encoding="utf-8")
            (result / SECRET).mkdir()
            (result / "report.xml").rename(result / SECRET / "report.xml")
        if case == "unreadable":
            result.chmod(0)
        elif case == "symlinks":
            (result / "report.xml").unlink()
            (result / "report.xml").symlink_to(base / "outside/secret")
            (output / "test-result-linked").symlink_to(base / "outside", target_is_directory=True)
        elif case == "unexpected":
            (output / ("test-result-" + SECRET + "\nname")).mkdir()
            for name in (SECRET, "pre-cluster-creation_123456.json\n" + SECRET,
                         "pre-" + SECRET + "_123456.xml"):
                (result / name).write_text(SECRET, encoding="utf-8")
        elif case in ("bounded", "bounded-reports"):
            for index in range(40):
                (result / f"post-clean_{index:06d}.xml").write_text(SECRET, encoding="utf-8")
            if case == "bounded":
                for index in range(40):
                    (output / f"test-result-{index}").mkdir()
        elif case in ("output-entry-limit", "result-entry-limit"):
            scan_directory = output if case == "output-entry-limit" else result
            for index in range(150):
                (scan_directory / f"ignored-{index}").touch()
        else:
            prepare_publication_case(base, case, output, result)
    return int(os.environ["FIXTURE_EXIT"])


class ArtifactFixture(unittest.TestCase):
    def setUp(self):
        self.base = Path(tempfile.mkdtemp())
        self.addCleanup(shutil.rmtree, self.base)
        self.bin = self.base / "bin"
        self.bin.mkdir()
        self.artifacts = self.base / "artifacts"
        self.artifacts.mkdir()
        self.shared = self.base / "shared"
        self.shared.mkdir()
        (self.base / "outside").mkdir()
        (self.base / "outside/secret").write_text(SECRET, encoding="utf-8")
        ref = (STEP / "rosa-e2e-ocm-fvt-ref.yaml").read_text(encoding="utf-8")
        commands = next(line.split(": ", 1)[1] for line in ref.splitlines()
                        if line.startswith("  commands: "))
        self.script = self.base / commands
        shutil.copyfile(STEP / commands, self.script)
        self.prepare_helpers()
        for command in ("podman", "cat", "env", "cp", "find", "python3", "oc"):
            executable = self.bin / command
            executable.write_text(
                f'#!/bin/bash\nexec "{sys.executable}" "{Path(__file__).resolve()}" '
                f'--mock {command} "$@"\n', encoding="utf-8")
            executable.chmod(0o755)

    def prepare_helpers(self):
        """Execute only the mounted prepare command, then remove its delivery volume."""
        ref = (STEP / "prepare/rosa-e2e-ocm-fvt-prepare-ref.yaml").read_text(encoding="utf-8")
        self.assertIn("  run_as_script: true\n", ref)
        commands = next(line.split(": ", 1)[1] for line in ref.splitlines()
                        if line.startswith("  commands: "))
        with tempfile.TemporaryDirectory(dir=self.base) as mount:
            delivered = Path(mount) / "rosa-e2e-ocm-fvt-prepare"
            shutil.copyfile(STEP / "prepare" / commands, delivered)
            delivered.chmod(0o700)
            subprocess.run([str(delivered)], env={"PATH": os.defpath,
                           "SHARED_DIR": str(self.shared)}, cwd=mount, check=True,
                           capture_output=True, text=True, timeout=10)
        self.assertEqual((self.shared / "ocm-fvt-artifacts.py").read_bytes(),
                         (STEP / "prepare" / commands).read_bytes())
        self.assertEqual(stat.S_IMODE((self.shared / "ocm-fvt-artifacts.py").stat().st_mode),
                         0o600)

    def execute_step(self, case="normal", exit_code=0):
        return subprocess.run(["bash", str(self.script)], env={
            "PATH": str(self.bin) + os.pathsep + os.defpath,
            "HOME": str(self.base), "ARTIFACT_DIR": str(self.artifacts),
            "SHARED_DIR": str(self.shared), "JOB_NAME": "fixture", "BUILD_ID": "1",
            "OCM_FVT_JOB_NAME": "fixture", "FIXTURE_DIR": str(self.base),
            "FIXTURE_CASE": case, "FIXTURE_EXIT": str(exit_code),
            "OCM_FVT_DEFER_CLEAN": str(case in ("copy-failure", "find-failure", "ready")).lower(),
        }, capture_output=True, text=True, timeout=30, umask=0o077, check=False)

    def run_step(self, case="normal", exit_code=0):
        result = self.execute_step(case, exit_code)
        self.assertEqual(result.returncode, exit_code, result.stderr)
        self.assertEqual((self.shared / "ocm-fvt-exit-code").read_text().strip(), str(exit_code))
        calls = [json.loads(line) for line in (self.base / "calls.jsonl").read_text().splitlines()]
        self.assertEqual([call[0] for call in calls], ["pull", "inspect", "run"])
        env_file = Path(calls[-1][calls[-1].index("--env-file") + 1])
        self.assertFalse(env_file.exists(), "EXIT trap must still remove the temporary env file")
        self.assertNotIn(SECRET, result.stdout + result.stderr)
        return result

    def metadata(self):
        path = self.artifacts / "ocm-fvt-artifact-metadata.json"
        self.assertEqual(stat.S_IMODE(path.stat().st_mode), 0o644)
        self.assertEqual(path.stat().st_uid, os.geteuid())
        contents = path.read_text(encoding="utf-8")
        self.assertNotIn(SECRET, contents)
        self.assertNotIn(str(self.base), contents)
        self.assertNotIn("test-result-", contents)
        self.assertLess(len(contents), 65000)
        return json.loads(contents)

    def tearDown(self):
        output = raw_output(self.base)
        if output.is_dir() and not output.is_symlink():
            output.chmod(0o700)
            result = output / "test-result-fixture"
            if result.is_dir():
                result.chmod(0o700)


class ArtifactPublicationTests(ArtifactFixture):
    def test_prepare_rejects_existing_helper_and_symlink(self):
        helper = self.shared / "ocm-fvt-artifacts.py"
        original = helper.read_bytes()
        with self.assertRaises(subprocess.CalledProcessError):
            self.prepare_helpers()
        self.assertEqual(helper.read_bytes(), original)
        helper.unlink()
        helper.symlink_to(self.base / "outside/secret")
        with self.assertRaises(subprocess.CalledProcessError):
            self.prepare_helpers()
        self.assertEqual((self.base / "outside/secret").read_text(), SECRET)

    def test_prepare_rejects_symlinked_shared_directory(self):
        self.shared.rename(self.base / "real-shared")
        self.shared.symlink_to(self.base / "real-shared", target_is_directory=True)
        with self.assertRaises(subprocess.CalledProcessError):
            self.prepare_helpers()

    def test_missing_delivered_helper_stops_before_producer(self):
        (self.shared / "ocm-fvt-artifacts.py").unlink()
        result = self.execute_step(exit_code=42)
        self.assertEqual(result.returncode, 1)
        self.assertIn("artifact helpers were not prepared", result.stderr)
        self.assertFalse((self.base / "calls.jsonl").exists())
        self.assertFalse((self.artifacts / "ocm-fvt-results").exists())

    def test_all_consumers_declare_helper_delivery(self):
        definitions, consumers = delivery_registry(REPOSITORY / "ci-operator/step-registry",
                                                  STEP / "rosa-e2e-ocm-fvt-commands.sh")
        self.assertIn("rosa-e2e-ocm-fvt", consumers)
        self.assertIn("rosa-e2e-ocm-fvt-longrunning", consumers)
        missing = []
        for config in (REPOSITORY / "ci-operator/config").rglob("*.yaml"):
            missing.extend((str(config), *failure) for failure in
                           missing_helper_delivery(read_yaml(config), definitions, consumers))
        self.assertEqual(missing, [])

    def test_delivery_dependencies_follow_symlinks_chains_and_workflows(self):
        registry = self.base / "registry"
        registry.mkdir()
        wrapper = registry / "original.sh"
        wrapper.write_text("wrapper", encoding="utf-8")
        (registry / "alias.sh").symlink_to(wrapper.name)
        entries = {
            "ref": {"as": "alias", "commands": "alias.sh"},
            "chain": {"as": "inner", "steps": [{"ref": "alias"}]},
            "workflow": {"as": "flow", "steps": {"test": [{"chain": "outer"}]}},
        }
        for kind, entry in entries.items():
            (registry / f"fixture-{kind}.yaml").write_text(yaml.safe_dump({kind: entry}),
                                                         encoding="utf-8")
        definitions, consumers = delivery_registry(registry, wrapper)
        self.assertEqual(consumers, {"alias"})
        definitions["chain"]["outer"] = {"steps": [{"chain": "inner"}]}
        configuration = {"tests": [{"as": "fixture", "steps": {"workflow": "flow"}}]}
        self.assertEqual(list(missing_helper_delivery(configuration, definitions, consumers)),
                         [("fixture", "test", "alias")])
        definitions["chain"]["outer"]["steps"].insert(0, {"ref": "rosa-e2e-ocm-fvt-prepare"})
        self.assertEqual(list(missing_helper_delivery(configuration, definitions, consumers)), [])
        definitions["chain"]["outer"]["steps"].pop(0)
        configuration["tests"][0]["steps"]["test"] = []
        self.assertEqual(list(missing_helper_delivery(configuration, definitions, consumers)), [])
        definitions["chain"]["inner"]["steps"] = [{"chain": "outer"}]
        with self.assertRaises(ValueError):
            list(expand_delivery_steps([{"chain": "outer"}], definitions["chain"]))

    @unittest.skipIf(os.geteuid() == 0, "Permission denial requires an unprivileged fixture user")
    def test_censor_temporary_file_and_atomic_replacement(self):
        self.run_step("permissions", 42)
        self.assertTrue((self.base / "before-denied").exists())
        source = raw_output(self.base) / "test-result-fixture"
        destination = self.artifacts / "ocm-fvt-results/test-result-fixture"
        report = destination / "report.xml"
        original = (source / "report.xml").read_bytes()
        self.assertEqual(original, b"<testsuites/>\n")
        self.assertEqual(report.read_bytes(), original)
        self.assertEqual(stat.S_IMODE(source.stat().st_mode), 0o555)
        self.assertEqual(stat.S_IMODE((source / "report.xml").stat().st_mode), 0o444)
        for directory in (destination.parent, destination):
            self.assertEqual(stat.S_IMODE(directory.stat().st_mode), 0o700)
            self.assertEqual(directory.stat().st_uid, os.geteuid())
        self.assertEqual(stat.S_IMODE(report.stat().st_mode), 0o600)
        self.assertEqual(report.stat().st_uid, os.geteuid())
        self.assertNotEqual(report.stat().st_ino, (source / "report.xml").stat().st_ino)
        with tempfile.NamedTemporaryFile(prefix="tmp-censor", dir=destination, delete=False) as temporary:
            temporary.write(b"censored fixture\n")
        os.replace(temporary.name, report)
        self.assertEqual(report.read_bytes(), b"censored fixture\n")
        self.assertEqual((source / "report.xml").read_bytes(), original)

    def test_diagnostics_preserved_and_private_state_excluded(self):
        result = self.run_step("publication-safety")
        output = self.artifacts / "ocm-fvt-results"
        source = raw_output(self.base)
        self.assertFalse((output / ".datainfo").exists())
        for name in ("cluster.ini", "kubeconfig", "guest.kubeconfig", "linked", "linked-directory", "fifo"):
            self.assertFalse((output / "test-result-fixture" / name).exists())
            self.assertTrue((source / "test-result-fixture" / name).exists())
        for original in (source / "diagnostics").iterdir():
            published = output / "diagnostics" / original.name
            self.assertEqual(published.read_bytes(), original.read_bytes())
            self.assertEqual(stat.S_IMODE(published.stat().st_mode), 0o600)
        self.assertEqual((self.base / "outside/secret").read_text(), SECRET)
        self.assertIn("excluded from publication", result.stdout)
        self.assertEqual(stat.S_IMODE(source.parent.stat().st_mode), 0o700)
        self.assertEqual(source.stat().st_dev, output.stat().st_dev)
        self.assertNotIn(self.artifacts, source.parents)

    def test_publication_failure_preserves_both_test_statuses(self):
        for exit_code in (0, 42):
            with self.subTest(exit_code=exit_code):
                result = self.run_step("publication-failure", exit_code)
                self.assertIn("raw output remains private", result.stdout)
                self.assertFalse((self.artifacts / "ocm-fvt-results").exists())
                self.assertTrue((raw_output(self.base) / "test-result-fixture/report.xml").exists())
                shutil.rmtree(raw_output(self.base).parent)
                (self.base / "calls.jsonl").unlink()
                for artifact in self.artifacts.iterdir():
                    artifact.unlink()

    def test_publication_size_bound_never_publishes_partial_tree(self):
        result = self.run_step("publication-bound", 42)
        self.assertIn("raw output remains private", result.stdout)
        self.assertFalse((self.artifacts / "ocm-fvt-results").exists())

    def test_publication_entry_bound_never_publishes_partial_tree(self):
        result = self.run_step("publication-entry-bound", 42)
        self.assertIn("raw output remains private", result.stdout)
        self.assertFalse((self.artifacts / "ocm-fvt-results").exists())

    def test_publication_depth_bound_never_publishes_partial_tree(self):
        result = self.run_step("publication-depth-bound", 42)
        self.assertIn("raw output remains private", result.stdout)
        self.assertFalse((self.artifacts / "ocm-fvt-results").exists())

    def test_setgid_parent_preserves_private_staging_and_exact_publication_modes(self):
        self.base.chmod(0o2700)
        self.run_step()
        source = raw_output(self.base)
        self.assertTrue(source.parent.stat().st_mode & stat.S_ISGID)
        self.assertEqual(stat.S_IMODE(source.parent.stat().st_mode) & 0o777, 0o700)
        output = self.artifacts / "ocm-fvt-results"
        self.assertEqual(stat.S_IMODE(output.stat().st_mode), 0o700)
        self.assertEqual(stat.S_IMODE((output / "test-result-fixture").stat().st_mode), 0o700)

    def test_ready_guest_state_and_deferred_clean_are_preserved(self):
        self.run_step("ready")
        self.assertTrue((self.base / "oc-called").exists())
        self.assertEqual((self.shared / "cluster-id").read_text(), "fixture-cluster")
        kubeconfig = self.shared / "kubeconfig"
        self.assertEqual(kubeconfig.read_text(), "apiVersion: v1\nkind: Config\n")
        self.assertEqual(stat.S_IMODE(kubeconfig.stat().st_mode), 0o600)
        for directory in (self.shared, self.artifacts):
            self.assertEqual((directory / "ocm-fvt-gather-eligible").read_text(), "true")
            with tarfile.open(directory / "ocm-fvt-clean-state.tgz") as archive:
                self.assertIn("test-result-fixture/cluster.ini", archive.getnames())
                self.assertIn("test-result-fixture/guest.kubeconfig", archive.getnames())
                self.assertIn(".datainfo", archive.getnames())
        published = self.artifacts / "ocm-fvt-results/test-result-fixture"
        self.assertFalse((published / "cluster.ini").exists())
        self.assertFalse((published / "guest.kubeconfig").exists())

    @unittest.skipIf(os.geteuid() == 0, "Permission denial requires an unprivileged fixture user")
    def test_stage_parent_denial_stops_before_producer(self):
        self.base.chmod(0o555)
        try:
            result = self.execute_step()
        finally:
            self.base.chmod(0o700)
        self.assertEqual(result.returncode, 1)
        self.assertIn("failed to prepare private ocm-fvt artifact staging", result.stderr)
        self.assertNotIn(SECRET, result.stdout + result.stderr)
        self.assertFalse((self.base / "calls.jsonl").exists())
        self.assertFalse((self.artifacts / "ocm-fvt-results").exists())

    def test_existing_publication_symlink_is_not_followed(self):
        destination = self.artifacts / "ocm-fvt-results"
        destination.symlink_to(self.base / "outside", target_is_directory=True)
        result = self.run_step(exit_code=42)
        self.assertIn("raw output remains private", result.stdout)
        self.assertTrue(destination.is_symlink())
        self.assertEqual((self.base / "outside/secret").read_text(), SECRET)


class ArtifactMetadataTests(ArtifactFixture):
    def test_failed_test_status(self):
        self.run_step(exit_code=42)
        self.metadata()

    def test_standard_failure_status(self):
        self.run_step(exit_code=1)
        self.metadata()

    def test_signal_status(self):
        self.run_step(exit_code=137)
        self.metadata()

    def test_identity_and_reports(self):
        self.run_step()
        data = self.metadata()
        self.assertEqual(data["collector"]["euid"], os.geteuid())
        self.assertEqual(data["collector"]["egid"], os.getegid())
        self.assertEqual(data["collector"]["groups"], os.getgroups()[:32])
        self.assertEqual(data["output"]["mode"], "1777")
        directory = data["output"]["results"][0]
        self.assertEqual(directory["uid"], os.geteuid())
        reports = {report["label"]: report for report in directory["reports"]}
        self.assertEqual(set(reports), {"merged-xml", "pre-cluster-creation-json"})
        self.assertEqual(reports["pre-cluster-creation-json"]["mode"], "0000")
        digest = self.artifacts / "ocm-fvt-image-digest.txt"
        self.assertEqual(digest.read_text().strip(), DIGEST)
        self.assertEqual(stat.S_IMODE(digest.stat().st_mode), 0o644)

    @unittest.skipIf(os.geteuid() == 0, "Permission denial requires an unprivileged fixture user")
    def test_unreadable_directory(self):
        self.run_step("unreadable", 42)
        directory = self.metadata()["output"]["results"][0]
        self.assertEqual(directory["mode"], "0000")
        self.assertEqual(directory["errno"], errno.EACCES)

    @unittest.skipIf(os.geteuid() == 0, "Permission denial requires an unprivileged fixture user")
    def test_unreadable_root(self):
        self.run_step("root-unreadable")
        self.assertEqual(self.metadata()["output"]["errno"], errno.EACCES)

    def test_missing_output(self):
        self.run_step("missing", 42)
        self.assertEqual(self.metadata()["output"], {"errno": errno.ENOENT})

    def test_bounded_output_entry_scan(self):
        self.run_step("output-entry-limit")
        self.assertTrue(self.metadata()["output"]["truncated"])

    def test_symlink_root(self):
        self.run_step("root-symlink")
        self.assertEqual(self.metadata()["output"]["type"], stat.S_IFLNK)
        self.assertNotIn("results", self.metadata()["output"])


class ArtifactSafetyTests(ArtifactFixture):
    def test_symlink_results_and_reports(self):
        self.run_step("symlinks")
        directories = self.metadata()["output"]["results"]
        self.assertTrue(any(directory["type"] == stat.S_IFLNK for directory in directories))
        reports = [report for directory in directories for report in directory.get("reports", [])]
        self.assertTrue(any(report["type"] == stat.S_IFLNK for report in reports))
        self.assertEqual((self.base / "outside/secret").read_text(), SECRET)

    def test_unexpected_names_and_contents_are_not_published(self):
        self.run_step("unexpected")
        self.assertEqual(sum(len(directory["reports"]) for directory in
                             self.metadata()["output"]["results"]), 2)

    def test_bounded_metadata(self):
        self.run_step("bounded")
        output = self.metadata()["output"]
        self.assertTrue(output["truncated"])
        self.assertEqual(len(output["results"]), 16)
        self.assertTrue(all(len(directory["reports"]) <= 32 for directory in output["results"]))

    def test_bounded_result_entry_scan(self):
        self.run_step("result-entry-limit")
        results = self.metadata()["output"]["results"]
        self.assertEqual(len(results), 1)
        self.assertTrue(results[0]["truncated"])

    def test_bounded_report_metadata(self):
        self.run_step("bounded-reports")
        directory = self.metadata()["output"]["results"][0]
        self.assertTrue(directory["truncated"])
        self.assertEqual(len(directory["reports"]), 32)

    def test_collector_does_not_follow_existing_artifact_symlink(self):
        artifact = self.artifacts / "ocm-fvt-artifact-metadata.json"
        artifact.symlink_to(self.base / "outside/secret")
        result = self.run_step()
        self.assertTrue(artifact.is_symlink())
        self.assertEqual((self.base / "outside/secret").read_text(), SECRET)
        self.assertIn("WARNING: failed to collect ocm-fvt artifact metadata", result.stdout)

    def test_digest_does_not_follow_existing_artifact_symlink(self):
        artifact = self.artifacts / "ocm-fvt-image-digest.txt"
        artifact.symlink_to(self.base / "outside/secret")
        self.run_step()
        self.assertTrue(artifact.is_symlink())
        self.assertEqual((self.base / "outside/secret").read_text(), SECRET)

    def test_artifact_symlinks_to_special_files_are_not_followed(self):
        for name in ("ocm-fvt-artifact-metadata.json", "ocm-fvt-image-digest.txt"):
            (self.artifacts / name).symlink_to("/dev/null")
        result = self.run_step(exit_code=42)
        self.assertIn("WARNING: failed to persist ocmci image digest", result.stdout)
        self.assertIn("WARNING: failed to collect ocm-fvt artifact metadata", result.stdout)

    def test_existing_fifos_do_not_block_artifact_creation(self):
        for name in ("ocm-fvt-artifact-metadata.json", "ocm-fvt-image-digest.txt"):
            os.mkfifo(self.artifacts / name)
        result = self.run_step()
        self.assertIn("WARNING: failed to persist ocmci image digest", result.stdout)
        self.assertIn("WARNING: failed to collect ocm-fvt artifact metadata", result.stdout)

    def test_existing_artifact_files_are_not_overwritten(self):
        for name in ("ocm-fvt-artifact-metadata.json", "ocm-fvt-image-digest.txt"):
            (self.artifacts / name).write_text(SECRET, encoding="utf-8")
        self.run_step()
        for name in ("ocm-fvt-artifact-metadata.json", "ocm-fvt-image-digest.txt"):
            self.assertEqual((self.artifacts / name).read_text(), SECRET)

    def test_invalid_digest_is_not_published(self):
        self.run_step("invalid-digest")
        self.assertFalse((self.artifacts / "ocm-fvt-image-digest.txt").exists())

    def test_inspect_failure_is_best_effort(self):
        self.run_step("inspect-failure")
        self.metadata()


class ArtifactPostprocessingTests(ArtifactFixture):
    def check_report_failure(self, case, exit_code):
        result = self.run_step(case, exit_code)
        self.metadata()
        operation = "copy ocm-fvt report" if case == "copy-failure" else "scan ocm-fvt reports"
        self.assertIn("WARNING: failed to " + operation, result.stdout)
        self.assertFalse((self.artifacts / "junit-ocm-fvt-report.xml").exists())
        self.assertEqual((self.shared / "cluster-id").read_text(), "fixture-cluster")
        for directory in (self.shared, self.artifacts):
            self.assertEqual((directory / "ocm-fvt-gather-eligible").read_text(), "false")
            self.assertEqual((directory / "ocm-fvt-job-name").read_text(), "fixture")
            with tarfile.open(directory / "ocm-fvt-clean-state.tgz") as archive:
                self.assertIn("test-result-fixture/cluster.ini", archive.getnames())
                self.assertIn(".datainfo", archive.getnames())

    def test_later_copy_failure_preserves_test_status(self):
        self.check_report_failure("copy-failure", 0)

    def test_later_copy_failure_preserves_failed_test_status(self):
        self.check_report_failure("copy-failure", 42)

    def test_later_find_failure_preserves_test_status(self):
        self.check_report_failure("find-failure", 0)

    def test_later_find_failure_preserves_failed_test_status(self):
        self.check_report_failure("find-failure", 42)

    def check_collector_failure(self, exit_code):
        result = self.run_step("collector-failure", exit_code)
        self.assertIn("WARNING: failed to collect ocm-fvt artifact metadata", result.stdout)
        self.assertNotIn("WARNING: failed to persist ocmci image digest", result.stdout)
        self.assertFalse((self.artifacts / "ocm-fvt-artifact-metadata.json").exists())
        self.assertEqual((self.artifacts / "ocm-fvt-image-digest.txt").read_text(), DIGEST + "\n")

    def test_collector_failure_preserves_test_status(self):
        self.check_collector_failure(42)

    def test_collector_failure_does_not_fail_successful_test(self):
        self.check_collector_failure(0)


if __name__ == "__main__":
    if len(sys.argv) > 1 and sys.argv[1] == "--mock":
        sys.exit(mock_command(sys.argv[2], sys.argv[3:]))
    unittest.main()
