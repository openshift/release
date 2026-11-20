#!/usr/bin/env python3
"""Exercise the must-gather tag resolvers without registry or cluster access."""

import json
import os
from pathlib import Path
import subprocess
import unittest


ROOT = Path(__file__).resolve().parents[4]
REGISTRY = ROOT / "ci-operator/step-registry/sandboxed-containers-operator"
SCRIPTS = (
    REGISTRY / "gather-must-gather/sandboxed-containers-operator-gather-must-gather-commands.sh",
    REGISTRY / "post-install/isolation/common/mirror-operator/sandboxed-containers-operator-post-install-isolation-common-mirror-operator-commands.sh",
)
IMAGE = "quay.io/redhat-user-workloads/ose-osc-tenant/osc-must-gather"


def page(names, additional=False):
    return json.dumps({"tags": [{"name": name} for name in names], "has_additional": additional})


class MustGatherResolverTest(unittest.TestCase):
    def resolve(self, script, image, first="", second="", fail=False):
        source = script.read_text()
        function = "resolve_must_gather_image() {" + source.split("resolve_must_gather_image() {", 1)[1].split("\n}\n", 1)[0] + "\n}\n"
        mock = r'''
curl() {
    [[ "${FAIL_CURL}" != true ]] || return 1
    case "$*" in
        *page=1\&*) printf '%s' "$PAGE_ONE" ;;
        *page=2\&*) printf '%s' "$PAGE_TWO" ;;
        *) return 1 ;;
    esac
}
'''
        env = dict(os.environ, PAGE_ONE=first, PAGE_TWO=second, FAIL_CURL=str(fail).lower())
        return subprocess.run(
            ["bash", "-euo", "pipefail", "-c", mock + function + 'resolve_must_gather_image "$1"', "test", image],
            env=env, text=True, capture_output=True, check=False,
        )

    def test_latest_uses_highest_epoch_across_pages(self):
        first = page(["latest", "pr-123", "1.14-1794506149", "1.14-9999999999.sig"], True)
        second = page(["1.15.0-1794506150", "sha256-deadbeef", "1.14-100"])
        for script in SCRIPTS:
            with self.subTest(script=script):
                result = self.resolve(script, f"{IMAGE}:latest", first, second)
                self.assertEqual(result.returncode, 0, result.stderr)
                self.assertEqual(result.stdout.strip(), f"{IMAGE}:1.15.0-1794506150")

    def test_explicit_image_is_not_resolved(self):
        for image in (f"{IMAGE}:pr-3800", f"{IMAGE}@sha256:abcdef", "example.org/custom:latest"):
            for script in SCRIPTS:
                with self.subTest(script=script, image=image):
                    result = self.resolve(script, image, fail=True)
                    self.assertEqual(result.returncode, 0, result.stderr)
                    self.assertEqual(result.stdout.strip(), image)

    def test_no_tag_invalid_response_and_network_failure(self):
        for script in SCRIPTS:
            for content, fail in ((page(["latest", "pr-123"]), False), ("not json", False), ("", True)):
                with self.subTest(script=script, content=content, fail=fail):
                    result = self.resolve(script, f"{IMAGE}:latest", content, fail=fail)
                    self.assertNotEqual(result.returncode, 0)
                    self.assertIn("ERROR:", result.stderr)


if __name__ == "__main__":
    unittest.main()
