#!/usr/bin/env python3

import importlib.util
import json
import sys
import tempfile
import textwrap
import unittest
from pathlib import Path

STEP_DIR = Path(__file__).resolve().parent
VALIDATOR_PATH = STEP_DIR / "validate_art_manifests.py"
spec = importlib.util.spec_from_file_location("validate_art_manifests", VALIDATOR_PATH)
assert spec and spec.loader
validate_art_manifests = importlib.util.module_from_spec(spec)
sys.modules["validate_art_manifests"] = validate_art_manifests
spec.loader.exec_module(validate_art_manifests)

BranchVersion = validate_art_manifests.BranchVersion
find_image_references_files = validate_art_manifests.find_image_references_files
resolve_release_branch = validate_art_manifests.resolve_release_branch
validate_repo = validate_art_manifests.validate_repo
format_failure_report = validate_art_manifests.format_failure_report


def write_fixture(path: Path, content: str) -> None:
    path.parent.mkdir(parents=True, exist_ok=True)
    path.write_text(textwrap.dedent(content).lstrip(), encoding="utf-8")


def build_fixture_tree(base: Path) -> None:
    write_fixture(
        base / "pass-quay/manifests/stable/image-references",
        """
        ---
        kind: ImageStream
        apiVersion: image.openshift.io/v1
        spec:
          tags:
          - name: operator
            from:
              kind: DockerImage
              name: quay.io/example/operator:latest
        """,
    )
    write_fixture(
        base / "pass-quay/manifests/stable/operator.clusterserviceversion.yaml",
        """
        apiVersion: operators.coreos.com/v1alpha1
        kind: ClusterServiceVersion
        metadata:
          name: operator.v4.23.0
        spec:
          relatedImages:
          - name: operator
            image: quay.io/example/operator:latest
        """,
    )

    write_fixture(
        base / "fail-r1-orphan/manifests/stable/image-references",
        """
        ---
        kind: ImageStream
        apiVersion: image.openshift.io/v1
        spec:
          tags:
          - name: orphan
            from:
              kind: DockerImage
              name: quay.io/orphan.example.com/image:tag
        """,
    )
    write_fixture(
        base / "fail-r1-orphan/manifests/stable/operator.clusterserviceversion.yaml",
        """
        apiVersion: operators.coreos.com/v1alpha1
        kind: ClusterServiceVersion
        metadata:
          name: operator.v4.23.0
        spec:
          relatedImages: []
        """,
    )

    write_fixture(
        base / "fail-r2-namespace/manifests/stable/image-references",
        """
        ---
        kind: ImageStream
        apiVersion: image.openshift.io/v1
        spec:
          tags:
          - name: mustgather
            from:
              kind: DockerImage
              name: registry.redhat.io/openshift4/ose-mustgather-rhel9:v4.22.0
        """,
    )
    write_fixture(
        base / "fail-r2-namespace/manifests/stable/operator.clusterserviceversion.yaml",
        """
        apiVersion: operators.coreos.com/v1alpha1
        kind: ClusterServiceVersion
        metadata:
          name: operator.v5.0.0
          annotations:
            operators.openshift.io/must-gather-image: registry.redhat.io/openshift4/ose-mustgather-rhel9:v4.22.0
        spec:
          relatedImages: []
        """,
    )

    write_fixture(
        base / "pass-r2-zstream/manifests/stable/image-references",
        """
        ---
        kind: ImageStream
        apiVersion: image.openshift.io/v1
        spec:
          tags:
          - name: mustgather
            from:
              kind: DockerImage
              name: registry.redhat.io/openshift4/ose-mustgather-rhel9:v4.22.0
        """,
    )
    write_fixture(
        base / "pass-r2-zstream/manifests/stable/operator.clusterserviceversion.yaml",
        """
        apiVersion: operators.coreos.com/v1alpha1
        kind: ClusterServiceVersion
        metadata:
          name: operator.v4.23.0
          annotations:
            operators.openshift.io/must-gather-image: registry.redhat.io/openshift4/ose-mustgather-rhel9:v4.22.0
        spec:
          relatedImages: []
        """,
    )

    write_fixture(
        base / "fail-r2-invalid-tag/manifests/stable/image-references",
        """
        ---
        kind: ImageStream
        apiVersion: image.openshift.io/v1
        spec:
          tags:
          - name: mustgather
            from:
              kind: DockerImage
              name: registry.redhat.io/openshift4/ose-mustgather-rhel9:not-a-version
        """,
    )
    write_fixture(
        base / "fail-r2-invalid-tag/manifests/stable/operator.clusterserviceversion.yaml",
        """
        apiVersion: operators.coreos.com/v1alpha1
        kind: ClusterServiceVersion
        metadata:
          name: operator.v4.23.0
          annotations:
            operators.openshift.io/must-gather-image: registry.redhat.io/openshift4/ose-mustgather-rhel9:not-a-version
        spec:
          relatedImages: []
        """,
    )

    write_fixture(
        base / "fail-r3-search/manifests/art.yaml",
        """
        updates:
          - file: stable/operator.clusterserviceversion.yaml
            update_list:
            - search: "version: {MAJOR}.{MINOR}.0"
              replace: "version: {FULL_VER}"
            - search: "does-not-exist-in-csv"
              replace: "replacement"
        """,
    )
    write_fixture(
        base / "fail-r3-search/manifests/stable/image-references",
        """
        ---
        kind: ImageStream
        apiVersion: image.openshift.io/v1
        spec:
          tags:
          - name: operator
            from:
              kind: DockerImage
              name: quay.io/example/operator:latest
        """,
    )
    write_fixture(
        base / "fail-r3-search/manifests/stable/operator.clusterserviceversion.yaml",
        """
        apiVersion: operators.coreos.com/v1alpha1
        kind: ClusterServiceVersion
        metadata:
          name: operator.v4.23.0
        spec:
          version: 4.23.0
          relatedImages:
          - name: operator
            image: quay.io/example/operator:latest
        """,
    )

    write_fixture(
        base / "pass-r3-empty-replace/manifests/art.yaml",
        """
        updates:
          - file: stable/operator.clusterserviceversion.yaml
            update_list:
            - search: "version: {MAJOR}.{MINOR}.0"
              replace: ""
        """,
    )
    write_fixture(
        base / "pass-r3-empty-replace/manifests/stable/image-references",
        """
        ---
        kind: ImageStream
        apiVersion: image.openshift.io/v1
        spec:
          tags:
          - name: operator
            from:
              kind: DockerImage
              name: quay.io/example/operator:latest
        """,
    )
    write_fixture(
        base / "pass-r3-empty-replace/manifests/stable/operator.clusterserviceversion.yaml",
        """
        apiVersion: operators.coreos.com/v1alpha1
        kind: ClusterServiceVersion
        metadata:
          name: operator.v4.23.0
        spec:
          version: 4.23.0
          relatedImages:
          - name: operator
            image: quay.io/example/operator:latest
        """,
    )

    write_fixture(
        base / "fail-malformed-image-references/manifests/stable/image-references",
        "",
    )

    write_fixture(
        base / "fail-nonmapping-artyaml/manifests/art.yaml",
        """
        plain string
        """,
    )
    write_fixture(
        base / "fail-nonmapping-artyaml/manifests/stable/image-references",
        """
        ---
        kind: ImageStream
        apiVersion: image.openshift.io/v1
        spec:
          tags:
          - name: operator
            from:
              kind: DockerImage
              name: quay.io/example/operator:latest
        """,
    )
    write_fixture(
        base / "fail-nonmapping-artyaml/manifests/stable/operator.clusterserviceversion.yaml",
        """
        apiVersion: operators.coreos.com/v1alpha1
        kind: ClusterServiceVersion
        metadata:
          name: operator.v4.23.0
        spec:
          relatedImages:
          - name: operator
            image: quay.io/example/operator:latest
        """,
    )


REPO_ROOT = STEP_DIR.parent.parent
COMMANDS_PATH = (
    REPO_ROOT
    / "ci-operator/step-registry/ocp-art/validate/art-manifests/ocp-art-validate-art-manifests-commands.sh"
)


def expected_embedded_python_source() -> str:
    source = VALIDATOR_PATH.read_text(encoding="utf-8")
    module_lines: list[str] = []
    for line in source.splitlines(keepends=True):
        if line.startswith('if __name__ == "__main__":'):
            break
        module_lines.append(line)
    return "".join(module_lines).rstrip() + "\n"


class ValidateArtManifestsTest(unittest.TestCase):
    @classmethod
    def setUpClass(cls) -> None:
        cls.temp_dir = tempfile.TemporaryDirectory()
        cls.fixtures = Path(cls.temp_dir.name)
        build_fixture_tree(cls.fixtures)
        (cls.fixtures / "no-image-references").mkdir()

    @classmethod
    def tearDownClass(cls) -> None:
        cls.temp_dir.cleanup()

    def test_skip_when_no_image_references(self) -> None:
        repo = self.fixtures / "no-image-references"
        self.assertEqual(validate_repo(repo, "release-4.23"), [])
        self.assertEqual(find_image_references_files(repo), [])

    def test_pass_minimal_quay_pullspecs(self) -> None:
        repo = self.fixtures / "pass-quay"
        self.assertEqual(validate_repo(repo, "release-4.23"), [])

    def test_fail_r1_orphan_pullspec(self) -> None:
        repo = self.fixtures / "fail-r1-orphan"
        violations = validate_repo(repo, "release-4.23")
        self.assertEqual(len(violations), 1)
        self.assertEqual(violations[0].rule, "R1")
        self.assertIn("orphan.example.com/image:tag", violations[0].pullspec or "")

    def test_fail_r2_wrong_namespace_on_release_5(self) -> None:
        repo = self.fixtures / "fail-r2-namespace"
        violations = validate_repo(repo, "release-5.0")
        rules = {violation.rule for violation in violations}
        self.assertIn("R2", rules)
        self.assertTrue(any("openshift5" in violation.message for violation in violations))

    def test_pass_r2_zstream_tag_on_release_4_23(self) -> None:
        repo = self.fixtures / "pass-r2-zstream"
        self.assertEqual(validate_repo(repo, "release-4.23"), [])

    def test_fail_r2_invalid_tag_on_release_4_23(self) -> None:
        repo = self.fixtures / "fail-r2-invalid-tag"
        violations = validate_repo(repo, "release-4.23")
        r2 = [violation for violation in violations if violation.rule == "R2"]
        self.assertEqual(len(r2), 1)
        self.assertIn("z-stream tag", r2[0].message)

    def test_fail_r3_missing_search(self) -> None:
        repo = self.fixtures / "fail-r3-search"
        violations = validate_repo(repo, "release-4.23")
        self.assertEqual(len(violations), 1)
        self.assertEqual(violations[0].rule, "R3")

    def test_pass_r3_empty_replace_allowed(self) -> None:
        repo = self.fixtures / "pass-r3-empty-replace"
        self.assertEqual(validate_repo(repo, "release-4.23"), [])

    def test_branch_version_parsing(self) -> None:
        branch = BranchVersion.from_release_branch("release-5.0")
        self.assertIsNotNone(branch)
        assert branch is not None
        self.assertEqual(branch.major, 5)
        self.assertEqual(branch.minor, 0)
        self.assertEqual(branch.template_values()["FULL_VER"], "5.0.0-0")

    def test_resolve_release_branch_from_pull_base_ref(self) -> None:
        branch, source = resolve_release_branch(pull_base_ref="release-4.23")
        self.assertEqual(branch, "release-4.23")
        self.assertEqual(source, "PULL_BASE_REF")

    def test_resolve_release_branch_ignores_main_in_job_spec(self) -> None:
        job_spec = json.dumps(
            {
                "refs": {
                    "org": "openshift",
                    "repo": "release",
                    "base_ref": "main",
                },
                "extra_refs": [
                    {
                        "org": "openshift",
                        "repo": "local-storage-operator",
                        "base_ref": "release-5.0",
                    }
                ],
            }
        )
        branch, source = resolve_release_branch(job_spec_json=job_spec)
        self.assertEqual(branch, "release-5.0")
        self.assertIn("extra_refs", source)

    def test_resolve_release_branch_skips_release_repo_refs(self) -> None:
        job_spec = json.dumps(
            {
                "refs": {
                    "org": "openshift",
                    "repo": "release",
                    "base_ref": "main",
                },
            }
        )
        with self.assertRaises(ValueError) as ctx:
            resolve_release_branch(job_spec_json=job_spec)
        self.assertIn("main/master are ignored", str(ctx.exception))

    def test_resolve_release_branch_explicit_override(self) -> None:
        job_spec = json.dumps(
            {
                "extra_refs": [
                    {
                        "org": "openshift",
                        "repo": "local-storage-operator",
                        "base_ref": "release-4.23",
                    }
                ],
            }
        )
        branch, source = resolve_release_branch(
            explicit="release-5.0",
            job_spec_json=job_spec,
        )
        self.assertEqual(branch, "release-5.0")
        self.assertEqual(source, "RELEASE_BRANCH")

    def test_resolve_release_branch_conflict(self) -> None:
        job_spec = json.dumps(
            {
                "extra_refs": [
                    {
                        "org": "openshift",
                        "repo": "local-storage-operator",
                        "base_ref": "release-4.23",
                    },
                    {
                        "org": "openshift",
                        "repo": "local-storage-operator",
                        "base_ref": "release-5.0",
                    },
                ],
            }
        )
        with self.assertRaises(ValueError) as ctx:
            resolve_release_branch(job_spec_json=job_spec)
        self.assertIn("Conflicting", str(ctx.exception))

    def test_fail_malformed_image_references(self) -> None:
        repo = self.fixtures / "fail-malformed-image-references"
        violations = validate_repo(repo, "release-4.23")
        self.assertEqual(len(violations), 1)
        self.assertEqual(violations[0].rule, "R1")
        self.assertIn("not a valid image-references file", violations[0].message)

    def test_fail_nonmapping_art_yaml(self) -> None:
        repo = self.fixtures / "fail-nonmapping-artyaml"
        violations = validate_repo(repo, "release-4.23")
        self.assertTrue(any(violation.rule == "R3" for violation in violations))
        self.assertTrue(
            any("did not parse to a mapping" in violation.message for violation in violations)
        )

    def test_failure_report_is_grouped_and_readable(self) -> None:
        repo = self.fixtures / "fail-r3-search"
        violations = validate_repo(repo, "release-4.23")
        report = format_failure_report(violations, "release-4.23", repo)
        self.assertIn("ART manifest check FAILED", report)
        self.assertIn("R3:", report)
        self.assertIn("How to fix:", report)
        self.assertIn("text art.yaml expects to find", report)
        self.assertNotIn("/go/src/github.com", report)

    def test_embedded_validator_matches_standalone_source(self) -> None:
        commands = COMMANDS_PATH.read_text(encoding="utf-8")
        start = commands.index("python3 <<'PYVALIDATOR'\n") + len("python3 <<'PYVALIDATOR'\n")
        end = commands.rindex("\nPYVALIDATOR")
        embedded = commands[start:end]
        wrapper_start = embedded.rfind('if __name__ == "__main__":')
        self.assertNotEqual(wrapper_start, -1)
        module_part = embedded[:wrapper_start].rstrip() + "\n"
        self.assertEqual(module_part, expected_embedded_python_source())


if __name__ == "__main__":
    unittest.main()
