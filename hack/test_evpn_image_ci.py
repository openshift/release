#!/usr/bin/env python3

import gzip
import io
import json
import shutil
import subprocess
import sys
import tarfile
import tempfile
import unittest
from pathlib import Path

ROOT = Path(__file__).resolve().parents[1]
STEP = ROOT / "ci-operator/step-registry/openshift/evpn-gateway-appliance/image-ci"
COMMANDS = STEP / "openshift-evpn-gateway-appliance-image-ci-commands.py"
SHA = "0123456789abcdef0123456789abcdef01234567"
IMAGE = b"oci-archive-bytes\n" * 5000
DISKS = {"qcow2": b"qcow2-disk-bytes\n" * 4000, "ami": b"raw-ami-disk-bytes\n" * 6000}
ARTIFACTS = {
    "disk.qcow2.gz": DISKS["qcow2"],
    "disk.ami.raw.gz": DISKS["ami"],
    "appliance-image.tar.gz": IMAGE,
}
SMOKE = """\
import json, os, sys
art = os.environ["ARTIFACT_DIR"]
seen = sorted(n for n in os.listdir(art) if not n.endswith(".partial"))
with open(os.environ["TEST_SMOKE_LOG"], "w") as f:
    json.dump({"artifacts": seen}, f)
sys.exit(int(os.environ["TEST_SMOKE_EXIT"]))
"""
CURL = """\
#!{python}
import os, shutil, sys
url = [a for a in sys.argv[1:] if a.startswith("http")][-1]
if "api.github.com" in url:
    sys.stdout.write(os.environ["TEST_SHA"])
elif url.endswith("/archive/" + os.environ["TEST_SHA"] + ".tar.gz"):
    out = sys.argv[sys.argv.index("-o") + 1] if "-o" in sys.argv else None
    if out:
        shutil.copyfile(os.environ["TEST_ARCHIVE"], out)
    else:
        sys.stdout.buffer.write(open(os.environ["TEST_ARCHIVE"], "rb").read())
else:
    sys.exit(22)
"""
GZIP = """\
#!{python}
import os, sys
args = sys.argv[1:]
if "--best" in args and os.path.basename(args[-1]) == os.environ.get("TEST_GZIP_FAIL"):
    sys.stdout.buffer.write(b"partial-compressed-bytes")
    sys.stdout.flush()
    sys.exit(1)
os.execv("{gzip}", ["gzip"] + args)
"""
PODMAN = """\
#!{python}
import os, sys
args = sys.argv[1:]
with open(os.environ["TEST_PODMAN_LOG"], "a") as f:
    f.write(args[0] + "\\n")
if args[0] == "build":
    sys.exit(0 if os.path.isfile("Containerfile") else 125)
if args[0] == "save":
    out = args[args.index("-o") + 1]
    with open(out, "wb") as f:
        f.write(open(os.environ["TEST_IMAGE"], "rb").read())
if args[0] == "run":
    out = [a.split(":/output")[0] for a in args if a.endswith(":/output")][0]
    kind = args[args.index("--type") + 1]
    name = {{"qcow2": "qcow2/disk.qcow2", "ami": "image/disk.raw"}}[kind]
    if kind != os.environ.get("TEST_NO_DISK"):
        path = os.path.join(out, name)
        os.makedirs(os.path.dirname(path), exist_ok=True)
        with open(path, "wb") as f:
            f.write(open(os.environ["TEST_DISK_" + kind.upper()], "rb").read())
"""


def make_archive(path, with_smoke):
    files = {"image/rhel10/Containerfile": b"FROM scratch\n"}
    if with_smoke:
        files["image/tools/smoke-payloads.py"] = SMOKE.encode()
    with tarfile.open(path, "w:gz") as tar:
        for name, data in files.items():
            info = tarfile.TarInfo(f"evpn-gateway-appliance-{SHA}/{name}")
            info.size = len(data)
            tar.addfile(info, io.BytesIO(data))


class ImageCITests(unittest.TestCase):
    def setUp(self):
        self.directory = Path(tempfile.mkdtemp())
        self.addCleanup(shutil.rmtree, self.directory, ignore_errors=True)
        self.bin = self.directory / "bin"
        self.artifacts = self.directory / "artifacts"
        self.home = self.directory / "home"
        for path in (
            self.bin,
            self.artifacts,
            self.home / ".docker",
            self.directory / "tmp",
        ):
            path.mkdir(parents=True)
        (self.home / ".docker/config.json").write_text("{}")
        for credentials in ("/var/run/registry-pull-credentials", "/etc/pull-secret"):
            if Path(credentials).exists():
                self.skipTest(f"{credentials} exists on this host")
        gzip_binary = shutil.which("gzip")
        for name, template in (("curl", CURL), ("podman", PODMAN), ("gzip", GZIP)):
            script = self.bin / name
            script.write_text(template.format(python=sys.executable, gzip=gzip_binary))
            script.chmod(0o755)
        self.fixtures = {}
        for name, data in {
            "image": IMAGE,
            **{f"disk_{k}": v for k, v in DISKS.items()},
        }.items():
            self.fixtures[name] = self.directory / name
            self.fixtures[name].write_bytes(data)
        self.environment = {
            "PATH": f"{self.bin}:/usr/bin:/bin",
            "HOME": str(self.home),
            "TMPDIR": str(self.directory / "tmp"),
            "WORKROOT": str(self.directory / "work"),
            "ARTIFACT_DIR": str(self.artifacts),
            "TEST_SHA": SHA,
            "TEST_ARCHIVE": str(self.directory / "source.tar.gz"),
            "TEST_IMAGE": str(self.fixtures["image"]),
            "TEST_DISK_QCOW2": str(self.fixtures["disk_qcow2"]),
            "TEST_DISK_AMI": str(self.fixtures["disk_ami"]),
            "TEST_PODMAN_LOG": str(self.directory / "podman.log"),
            "TEST_SMOKE_LOG": str(self.directory / "smoke.json"),
            "TEST_SMOKE_EXIT": "0",
        }
        make_archive(self.environment["TEST_ARCHIVE"], with_smoke=True)

    def run_step(self, **overrides):
        return subprocess.run(
            [sys.executable, str(COMMANDS)],
            env={**self.environment, **overrides},
            cwd=self.directory,
            capture_output=True,
            text=True,
            check=False,
        )

    def seed_previous_artifacts(self):
        for name in ARTIFACTS:
            (self.artifacts / name).write_bytes(
                gzip.compress(b"previous " + name.encode())
            )

    def assert_published(self, names):
        for name in names:
            data = gzip.decompress((self.artifacts / name).read_bytes())
            self.assertEqual(data, ARTIFACTS[name], name)

    def podman_calls(self):
        log = Path(self.environment["TEST_PODMAN_LOG"])
        return log.read_text().split() if log.exists() else []

    def test_publishes_gunzippable_artifacts_of_the_built_content(self):
        result = self.run_step()
        self.assertEqual(result.returncode, 0, result.stderr)
        self.assertEqual(
            sorted(p.name for p in self.artifacts.iterdir()), sorted(ARTIFACTS)
        )
        self.assert_published(ARTIFACTS)

    def test_compress_failure_keeps_previous_artifact_and_leaves_no_partial(self):
        for failing, artifact in (
            ("disk.qcow2", "disk.qcow2.gz"),
            ("disk.raw", "disk.ami.raw.gz"),
            ("appliance-image.tar", "appliance-image.tar.gz"),
        ):
            with self.subTest(failing=failing):
                shutil.rmtree(self.artifacts)
                self.artifacts.mkdir()
                self.seed_previous_artifacts()
                previous = (self.artifacts / artifact).read_bytes()
                result = self.run_step(TEST_GZIP_FAIL=failing)
                self.assertNotEqual(result.returncode, 0)
                self.assertEqual((self.artifacts / artifact).read_bytes(), previous)
                self.assertEqual(list(self.artifacts.glob("*.partial")), [])

    def test_smoke_failure_is_nonfatal_and_runs_after_all_artifacts_are_saved(self):
        result = self.run_step(TEST_SMOKE_EXIT="3")
        self.assertEqual(result.returncode, 0, result.stderr)
        self.assert_published(ARTIFACTS)
        smoke = json.loads(Path(self.environment["TEST_SMOKE_LOG"]).read_text())
        self.assertEqual(smoke["artifacts"], sorted(ARTIFACTS))

    def test_missing_smoke_script_is_nonfatal(self):
        make_archive(self.environment["TEST_ARCHIVE"], with_smoke=False)
        result = self.run_step()
        self.assertEqual(result.returncode, 0, result.stderr)
        self.assert_published(ARTIFACTS)
        self.assertFalse(Path(self.environment["TEST_SMOKE_LOG"]).exists())

    def test_missing_disk_fails_without_publishing_it(self):
        for kind, artifact in (("qcow2", "disk.qcow2.gz"), ("ami", "disk.ami.raw.gz")):
            with self.subTest(kind=kind):
                result = self.run_step(TEST_NO_DISK=kind)
                self.assertNotEqual(result.returncode, 0)
                self.assertFalse((self.artifacts / artifact).exists())
                self.assertFalse((self.artifacts / "appliance-image.tar.gz").exists())

    def test_unverified_source_or_missing_pull_secret_builds_nothing(self):
        secret = self.home / ".docker/config.json"
        for label, has_secret, sha in (
            ("no pull secret", False, SHA),
            ("bad sha", True, "not-a-sha"),
        ):
            with self.subTest(label):
                secret.unlink(missing_ok=True)
                if has_secret:
                    secret.write_text("{}")
                result = self.run_step(TEST_SHA=sha)
                self.assertNotEqual(result.returncode, 0)
                self.assertEqual(self.podman_calls(), [])
                self.assertEqual(list(self.artifacts.iterdir()), [])


if __name__ == "__main__":
    unittest.main(verbosity=2)
