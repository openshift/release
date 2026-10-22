#!/usr/bin/env python3
"""Hermetic regression tests for custom mirroring and the cloud handler wrapper."""

import contextlib
import os
import re
import subprocess
import tempfile
import textwrap
import unittest
from pathlib import Path

import yaml


ROOT = Path(__file__).resolve().parent.parent
REGISTRY = ROOT / "ci-operator/step-registry"
MIRROR_SCRIPT = REGISTRY / "mirror-images/custom/mirror-images-custom-commands.sh"
CLOUD_SCRIPT = (
    REGISTRY
    / "kubernetes-nmstate/e2e/handler/cloud/kubernetes-nmstate-e2e-handler-cloud-commands.sh"
)
DIGEST = "sha256:" + "a" * 64
OTHER_DIGEST = "sha256:" + "b" * 64

# No network, mounted credentials, or actual bastion files are accessed. The SSH
# double uses a real shell so unsafe interpolation still has its real behavior.
MIRROR_BOUNDARIES = r"""
head() {
  if [[ "${@: -1}" == /var/run/vault/mirror-registry/registry_creds ]]; then
    printf '%s\n' 'fixture-user:fixture-password'
  else
    command head "$@"
  fi
}
oc() {
  case "${1:-} ${2:-}" in
    'registry login'|'version --client') return 0 ;;
    'get imagestream')
      if [[ "$*" == *publicDockerImageRepository* ]]; then
        printf '%s' "${PIPELINE_REPO}"
      fi
      ;;
    'get istag')
      if [[ "$*" == *image.metadata.name* ]]; then
        if [[ "$3" == pipeline:operator ]]; then
          printf '%s' "${OTHER_DIGEST}"
        else
          printf '%s' "${DIGEST}"
        fi
      fi
      ;;
    'get builds') return 0 ;;
    'image mirror')
      if [[ "$*" == *--help* ]]; then
        printf '%s\n' '--keep-manifest-list'
      else
        printf '%s\t' "$@" >> "${OC_LOG}"
        printf '\n' >> "${OC_LOG}"
      fi
      ;;
    'image info')
      printf '%s\t' "$@" >> "${OC_LOG}"
      printf '\n' >> "${OC_LOG}"
      ;;
    *) printf 'Unexpected oc invocation\n' >&2; return 1 ;;
  esac
}
which() {
  if [[ "$1" == oc ]]; then printf 'oc\n'; else command which "$@"; fi
}
ssh() {
  printf 'ssh\n' >> "${SSH_LOG}"
  while [[ "${1:-}" == -o ]]; do shift 2; done
  shift
  # Cleanup belongs to the mocked remote host, never the developer's /tmp.
  if [[ "$*" == 'rm -f /tmp/mirror-images-custom-auth.json' ]]; then return 0; fi
  command bash --noprofile --norc -c "$*"
}
scp() { return 0; }
sleep() { return 0; }
whoami() { printf 'fixture-user\n'; }
export -f oc which
"""


class ScriptFixtures(unittest.TestCase):
    def setUp(self):
        self.resources = contextlib.ExitStack()
        self.addCleanup(self.resources.close)
        self.root = Path(self.resources.enter_context(
            tempfile.TemporaryDirectory(prefix="mirror-images-custom-")
        ))
        self.run_count = 0
        self.shared = self.root / "shared"
        self.oc_log = self.root / "oc.log"
        self.ssh_log = self.root / "ssh.log"
        self.make_log = self.root / "make.log"

    def environment(self):
        self.run_count += 1
        work = self.root / str(self.run_count)
        self.shared = work / "shared"
        profile = work / "profile"
        home = work / "home"
        for directory in (self.shared, profile, home):
            directory.mkdir(parents=True)
        (profile / "pull-secret").write_text('{"auths":{}}', encoding="utf-8")
        self.oc_log = work / "oc.log"
        self.ssh_log = work / "ssh.log"
        self.make_log = work / "make.log"
        return dict(
            os.environ,
            BASH_ENV="/dev/null",
            HOME=str(home),
            TMPDIR=str(work),
            SHARED_DIR=str(self.shared),
            CLUSTER_PROFILE_DIR=str(profile),
            NAMESPACE="ci-fixture",
            PIPELINE_REPO="registry.example/ci-fixture/pipeline",
            DIGEST=DIGEST,
            OTHER_DIGEST=OTHER_DIGEST,
            OC_LOG=str(self.oc_log),
            SSH_LOG=str(self.ssh_log),
            MAKE_LOG=str(self.make_log),
        )

    @staticmethod
    def run_script(path, boundary, env):
        return subprocess.run(
            ["bash", "--noprofile", "--norc", "-c", boundary + path.read_text(encoding="utf-8")],
            env=env,
            capture_output=True,
            text=True,
            timeout=10,
            check=False,
        )

    def run_mirror(self, images, *, family="icsp", bastion=False):
        env = self.environment()
        env.update(
            MIRROR_CUSTOM_IMAGES=images,
            MIRROR_IN_BASTION="yes" if bastion else "no",
            CUSTOM_MIRROR_APPLY_MODE="manifest",
        )
        for name, value in {
            "mirror_registry_url": "mirror.example:5000",
            "bastion_private_address": "192.0.2.1",
            "bastion_ssh_user": "fixture-user",
            "install-config-mirror.yaml.patch": (
                "imageDigestSources: []" if family == "idms" else "imageContentSources: []"
            ),
        }.items():
            (self.shared / name).write_text(value + "\n", encoding="utf-8")
        return self.run_script(MIRROR_SCRIPT, MIRROR_BOUNDARIES, env)

    def assert_success(self, result):
        self.assertEqual(result.returncode, 0, result.stdout + result.stderr)

    def image_calls(self, verb):
        if not self.oc_log.exists():
            return []
        return [
            fields
            for line in self.oc_log.read_text(encoding="utf-8").splitlines()
            if (fields := line.rstrip("\t").split("\t"))[:2] == ["image", verb]
        ]

    def manifest(self, suffix):
        path = self.shared / f"manifest_mirror-images-custom-{suffix}.yaml"
        return yaml.safe_load(path.read_text(encoding="utf-8"))


class MirrorImagesCustomTests(ScriptFixtures):
    def test_bastion_arguments_are_literal_in_posix_shell(self):
        helper = re.search(
            r"(?ms)^function bssh_args\(\) \{.*?^\}",
            MIRROR_SCRIPT.read_text(encoding="utf-8"),
        )
        self.assertIsNotNone(helper, "The bastion argv helper must quote each argument")
        arguments = [
            "image with spaces", "semi;colon", "single'quote",
            "$(printf INJECTION_REACHED)", "`printf INJECTION_REACHED`", "two\nlines",
        ]
        result = subprocess.run(
            ["bash", "--noprofile", "--norc", "-c",
             'bssh() { sh -c "$1"; }\n' + helper.group(0)
             + '\nbssh_args printf "%s\\0" "$@"', "quote-fixture", *arguments],
            env=dict(os.environ, BASH_ENV="/dev/null"),
            capture_output=True, text=True, timeout=10, check=False,
        )
        self.assert_success(result)
        self.assertEqual(result.stdout, "\0".join(arguments) + "\0")

    def test_digest_registry_port_is_preserved(self):
        for bastion in (False, True):
            with self.subTest(bastion=bastion):
                result = self.run_mirror(
                    f"registry.example:5000/team/image@{DIGEST}", bastion=bastion
                )
                self.assert_success(result)
                self.assertEqual(
                    self.manifest("icsp")["spec"]["repositoryDigestMirrors"],
                    [{"source": "registry.example:5000/team/image",
                      "mirrors": ["mirror.example:5000/team/image"]}],
                )
                self.assertEqual(
                    self.image_calls("mirror")[0][-1],
                    f"registry.example:5000/team/image@{DIGEST}=mirror.example:5000/team/image",
                )
                self.assertEqual(
                    self.image_calls("info")[0][-1], f"mirror.example:5000/team/image@{DIGEST}"
                )

    def test_tagless_registry_port_defaults_to_latest(self):
        for bastion in (False, True):
            with self.subTest(bastion=bastion):
                result = self.run_mirror(
                    "registry.example:5000/team/image", family="idms", bastion=bastion
                )
                self.assert_success(result)
                self.assertEqual(
                    self.image_calls("mirror")[0][-1],
                    "registry.example:5000/team/image:latest=mirror.example:5000/team/image:latest",
                )
                self.assertEqual(
                    self.manifest("itms")["spec"]["imageTagMirrors"],
                    [{"source": "registry.example:5000/team/image",
                      "mirrors": ["mirror.example:5000/team/image"],
                      "mirrorSourcePolicy": "NeverContactSource"}],
                )

    def test_explicit_tag_with_registry_port_is_preserved(self):
        result = self.run_mirror("registry.example:5000/team/image:v1", family="idms")
        self.assert_success(result)
        self.assertEqual(
            self.image_calls("mirror")[0][-1],
            "registry.example:5000/team/image:v1=mirror.example:5000/team/image:v1",
        )

    def test_digest_takes_precedence_over_optional_tag(self):
        result = self.run_mirror(f"registry.example:5000/team/image:v1@{DIGEST}")
        self.assert_success(result)
        self.assertEqual(
            self.manifest("icsp")["spec"]["repositoryDigestMirrors"][0]["source"],
            "registry.example:5000/team/image",
        )
        self.assertEqual(self.image_calls("info")[0][-1], f"mirror.example:5000/team/image@{DIGEST}")

    def test_tagless_source_without_port_is_pinned_to_latest(self):
        result = self.run_mirror("registry.example/team/image", family="idms")
        self.assert_success(result)
        self.assertEqual(
            self.image_calls("mirror")[0][-1],
            "registry.example/team/image:latest=mirror.example:5000/team/image:latest",
        )

    def test_unsupported_ipv6_registry_literal_is_rejected_before_ssh(self):
        for bastion in (False, True):
            with self.subTest(bastion=bastion):
                result = self.run_mirror(f"[2001:db8::1]:5000/team/image@{DIGEST}", bastion=bastion)
                self.assertNotEqual(result.returncode, 0)
                self.assertIn("IPv6 registry", result.stderr)
                self.assertFalse(self.image_calls("mirror"))
                self.assertFalse(self.ssh_log.exists())
                self.assertFalse(list(self.shared.glob("manifest_*.yaml")))

    def test_pipeline_images_keep_distinct_digests_in_one_repository(self):
        for bastion in (False, True):
            with self.subTest(bastion=bastion):
                result = self.run_mirror("handler,operator", bastion=bastion)
                self.assert_success(result)
                self.assertEqual(
                    [call[-1] for call in self.image_calls("mirror")],
                    [f"registry.example/ci-fixture/pipeline@{DIGEST}=mirror.example:5000/ci-fixture/pipeline",
                     f"registry.example/ci-fixture/pipeline@{OTHER_DIGEST}=mirror.example:5000/ci-fixture/pipeline"],
                )
                self.assertEqual(len(self.manifest("icsp")["spec"]["repositoryDigestMirrors"]), 1)

    def test_idms_and_itms_are_emitted_for_mixed_references(self):
        result = self.run_mirror(
            f"registry.example/team/image@{DIGEST},registry.example/team/other:v1", family="idms"
        )
        self.assert_success(result)
        self.assertEqual(self.manifest("idms")["kind"], "ImageDigestMirrorSet")
        self.assertEqual(self.manifest("itms")["kind"], "ImageTagMirrorSet")
        self.assertEqual(
            self.manifest("idms")["spec"]["imageDigestMirrors"][0]["mirrorSourcePolicy"],
            "NeverContactSource",
        )

    def test_tag_is_rejected_under_icsp_before_mirroring(self):
        result = self.run_mirror("registry.example/team/image:v1", bastion=True)
        self.assertNotEqual(result.returncode, 0)
        self.assertIn("require the IDMS/ITMS family", result.stderr)
        self.assertFalse(self.image_calls("mirror"))
        self.assertFalse(self.ssh_log.exists())

    def test_empty_input_remains_a_noop(self):
        result = self.run_mirror("")
        self.assert_success(result)
        self.assertEqual((self.shared / "install-pre-config-status.txt").read_text(), "0\n")
        self.assertFalse(list(self.shared.glob("manifest_*.yaml")))
        self.assertFalse(self.image_calls("mirror"))

    def test_surrounding_whitespace_and_empty_entries_are_allowed(self):
        result = self.run_mirror(f" , registry.example/team/image@{DIGEST} , , ")
        self.assert_success(result)
        self.assertEqual(len(self.image_calls("mirror")), 1)

    def test_malformed_and_shell_inputs_are_rejected_before_ssh(self):
        for value in (
            f"registry.example/team/image@{DIGEST};printf${{IFS}}INJECTION_REACHED",
            "registry.example/team/image:$(printf INJECTION_REACHED)",
            "registry.example/team/image:`printf INJECTION_REACHED`",
            "registry.example/team/im'age:v1",
            "registry.example/team/im age:v1",
            "registry.example/team/Image:v1",
            "registry.example//image:v1",
            "registry.example/team/image@sha256:invalid",
            "https://registry.example/team/image:v1",
            "bad$(printf INJECTION_REACHED)",
            "-operator",
        ):
            with self.subTest(value=value):
                result = self.run_mirror(value, family="idms", bastion=True)
                self.assertNotEqual(result.returncode, 0, result.stdout + result.stderr)
                self.assertFalse(self.image_calls("mirror"))
                self.assertFalse(self.ssh_log.exists())
                self.assertFalse(list(self.shared.glob("manifest_*.yaml")))


class CloudHandlerTests(ScriptFixtures):
    def run_cloud(self, proxy=None, shared_dir=True):
        env = self.environment()
        if proxy is not None:
            (self.shared / "proxy-conf.sh").write_text(proxy, encoding="utf-8")
        if not shared_dir:
            env.pop("SHARED_DIR")
        boundary = textwrap.dedent("""\
            make() { printf '%s\\n' "${FIXTURE_PROXY:-}" > "${MAKE_LOG}"; }
            """)
        return self.run_script(CLOUD_SCRIPT, boundary, env)

    def test_proxy_setup_failure_stops_before_tests(self):
        result = self.run_cloud("return 37\n")
        self.assertEqual(result.returncode, 37, result.stdout + result.stderr)
        self.assertFalse(self.make_log.exists())

    def test_successful_proxy_setup_reaches_tests(self):
        result = self.run_cloud("export FIXTURE_PROXY=proxy-configured\n")
        self.assert_success(result)
        self.assertEqual(self.make_log.read_text(), "proxy-configured\n")

    def test_connected_run_without_proxy_reaches_tests(self):
        result = self.run_cloud()
        self.assert_success(result)
        self.assertTrue(self.make_log.exists())

    def test_missing_shared_directory_stops_before_tests(self):
        result = self.run_cloud(shared_dir=False)
        self.assertNotEqual(result.returncode, 0)
        self.assertFalse(self.make_log.exists())


if __name__ == "__main__":
    unittest.main()
