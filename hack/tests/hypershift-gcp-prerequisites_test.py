#!/usr/bin/env python3
"""Test prerequisite download/install behavior (requires Linux/GNU sed like CI).

Run with: python3 hack/tests/hypershift-gcp-prerequisites_test.py
"""

from http.server import BaseHTTPRequestHandler, ThreadingHTTPServer
import json
import os
from pathlib import Path
import subprocess
import tempfile
import threading
import unittest


ROOT = Path(__file__).resolve().parents[2]
SCRIPT = ROOT / "ci-operator/step-registry/hypershift/gcp/gke/prerequisites/hypershift-gcp-gke-prerequisites-commands.sh"
REF = SCRIPT.with_name("hypershift-gcp-gke-prerequisites-ref.yaml")
FILENAMES = (
    "monitoring.coreos.com_servicemonitors.yaml",
    "monitoring.coreos.com_prometheusrules.yaml",
    "monitoring.coreos.com_podmonitors.yaml",
    "routes.crd.yaml",
    "cert-manager.yaml",
)


class PrerequisitesTest(unittest.TestCase):
    def run_script(self, fail_download="", fail_apply=""):
        with tempfile.TemporaryDirectory() as directory:
            root = Path(directory)
            oc = root / "oc"
            oc.write_text(
                "#!/usr/bin/env python3\n"
                "import json, os, pathlib, sys\n"
                "root = pathlib.Path(os.environ['MOCK_ROOT'])\n"
                "args = sys.argv[1:]\n"
                "record = {'args': args}\n"
                "if args[:2] == ['apply', '-f']:\n"
                " if args[2] == '-': record['manifest'] = sys.stdin.read()\n"
                " else: record['manifest'] = pathlib.Path(args[2]).read_text()\n"
                "with (root / 'calls').open('a') as f: f.write(json.dumps(record) + '\\n')\n"
                "if args[:2] == ['apply', '-f']:\n"
                " if os.environ['MOCK_FAIL_APPLY'] == 'first': sys.exit(17)\n"
                " if os.environ['MOCK_FAIL_APPLY'] == 'cert-manager' and 'cert-manager.yaml' in record['manifest']: sys.exit(17)\n"
                "if args and args[0] == 'get': print('webhook-ca-bundle')\n"
            )
            curl = root / "curl"
            curl.write_text(
                "#!/usr/bin/env python3\n"
                "import json, os, pathlib, sys\n"
                "root = pathlib.Path(os.environ['MOCK_ROOT'])\n"
                "args = sys.argv[1:]\n"
                "url = next(x for x in args if x.startswith('https://'))\n"
                "with (root / 'downloads').open('a') as f: f.write(json.dumps(args) + '\\n')\n"
                "output = pathlib.Path(args[args.index('--output') + 1])\n"
                "if os.environ['MOCK_FAIL_DOWNLOAD'] and os.environ['MOCK_FAIL_DOWNLOAD'] in url:\n"
                " output.write_text('PARTIAL_DOWNLOAD_MUST_NOT_BE_APPLIED')\n"
                " print('curl: (22) The requested URL returned error: 503', file=sys.stderr)\n"
                " sys.exit(22)\n"
                "output.write_text('# source: ' + url + '\\nleader-election-namespace=kube-system\\n')\n"
            )
            for executable in (oc, curl):
                executable.chmod(0o755)
            for name in ("wget", "sleep"):
                stub = root / name
                stub.write_text('#!/bin/bash\necho "Unexpected command: $0" >&2\nexit 99\n')
                stub.chmod(0o755)
            env = dict(
                os.environ,
                PATH=f"{root}:{os.environ['PATH']}",
                TMPDIR=str(root),
                MOCK_ROOT=str(root),
                MOCK_FAIL_APPLY=fail_apply,
                MOCK_FAIL_DOWNLOAD=fail_download,
            )
            result = subprocess.run(["bash", str(SCRIPT)], env=env, capture_output=True, text=True, timeout=30, check=False)
            calls = [json.loads(line) for line in (root / "calls").read_text().splitlines()] if (root / "calls").exists() else []
            downloads = [json.loads(line) for line in (root / "downloads").read_text().splitlines()]
            self.assertEqual(list(root.glob("tmp.*")), [], "temporary manifests must be cleaned up")
            return result, calls, downloads

    def test_preserves_installer_image(self):
        reference = REF.read_text()
        self.assertIn('  from_image:\n    namespace: ocp\n    name: "4.22"\n    tag: upi-installer\n', reference)
        self.assertNotIn("hypershift-tests", reference)

    def test_pinned_downloads_and_installation(self):
        result, calls, downloads = self.run_script()
        self.assertEqual(result.returncode, 0, result.stderr)
        self.assertNotIn("Unexpected command", result.stderr)
        urls = [next(x for x in args if x.startswith("https://")) for args in downloads]
        self.assertEqual(len(urls), 5)
        self.assertEqual([url.rsplit("/", 1)[1] for url in urls], list(FILENAMES))
        for url in urls[:3]:
            self.assertIn("/854d33a40caad1dd773f73deb55726732803bcb8/", url)
        self.assertIn("/6bababe9164ea6c78274fd79c94a3f951f8d5ab2/", urls[3])
        self.assertIn("/v1.14.0/", urls[4])
        for args in downloads:
            for option, value in (("--retry", "5"), ("--retry-max-time", "90"), ("--connect-timeout", "10"), ("--max-time", "30")):
                self.assertEqual(args[args.index(option) + 1], value)
            for option in ("--fail", "--show-error", "--retry-all-errors"):
                self.assertIn(option, args)
            self.assertNotIn("--retry-delay", args)  # retain curl's exponential backoff
        applies = [c for c in calls if c["args"][:2] == ["apply", "-f"]]
        self.assertEqual(len(applies), 6)
        for apply, url in zip(applies[:5], urls):
            self.assertIn(url, apply["manifest"])
        self.assertIn("leader-election-namespace=cert-manager", applies[4]["manifest"])
        self.assertNotIn("kube-system", applies[4]["manifest"])
        self.assertIn("kind: ClusterIssuer", applies[5]["manifest"])
        patches = [c for c in calls if c["args"][0] == "patch"]
        self.assertEqual(len(patches), 3)
        for patch, name in zip(patches, ("cert-manager-controller", "cert-manager-webhook", "cert-manager-cainjector")):
            container = json.loads(patch["args"][-1])["spec"]["template"]["spec"]["containers"][0]
            self.assertEqual(container["name"], name)
            self.assertEqual(container["resources"]["requests"], {"cpu": "50m", "memory": "64Mi"})
        self.assertEqual(len([c for c in calls if c["args"][0] == "wait"]), 3)

    def test_failed_downloads_are_not_applied(self):
        for index, filename in enumerate(FILENAMES):
            with self.subTest(filename=filename):
                result, calls, downloads = self.run_script(fail_download=filename)
                self.assertEqual(result.returncode, 22)
                self.assertEqual(len(calls), index)
                self.assertEqual(len(downloads), index + 1)
                self.assertIn("Failed to download prerequisite manifest", result.stderr)
                self.assertIn(filename, result.stderr)
                self.assertIn("returned error: 503", result.stderr)
                self.assertNotIn("PARTIAL_DOWNLOAD", json.dumps(calls))

    def test_apply_failures_propagate(self):
        for target, count in (("first", 1), ("cert-manager", 5)):
            with self.subTest(target=target):
                result, calls, downloads = self.run_script(fail_apply=target)
                self.assertEqual(result.returncode, 17)
                self.assertEqual(len(calls), count)
                self.assertEqual(len(downloads), count)

    def test_real_curl_recovers_from_http_503(self):
        class Handler(BaseHTTPRequestHandler):
            attempts = 0

            def do_GET(self):  # pylint: disable=invalid-name
                Handler.attempts += 1
                self.send_response(503 if Handler.attempts == 1 else 200)
                self.end_headers()
                self.wfile.write(b"unavailable" if Handler.attempts == 1 else b"valid-manifest")

            def log_message(self, *_args):
                pass

        server = ThreadingHTTPServer(("127.0.0.1", 0), Handler)
        thread = threading.Thread(target=server.serve_forever, daemon=True)
        thread.start()
        try:
            with tempfile.TemporaryDirectory() as directory:
                # Run the real download helper and real curl against loopback only.
                header = SCRIPT.read_text().split("\nset -x\n", 1)[0]
                command = header + '\ndownload_manifest "$1" "${MANIFEST_TMP_FILE}"\ncat "${MANIFEST_TMP_FILE}"\n'
                url = f"http://127.0.0.1:{server.server_port}/manifest.yaml"
                result = subprocess.run(
                    ["bash", "-c", command, "test", url],
                    env=dict(os.environ, TMPDIR=directory, NO_PROXY="127.0.0.1", no_proxy="127.0.0.1"),
                    capture_output=True, text=True, timeout=15, check=False,
                )
                self.assertEqual(result.returncode, 0, result.stderr)
                self.assertEqual(Handler.attempts, 2)
                self.assertTrue(result.stdout.endswith("valid-manifest"))
                self.assertNotIn("unavailable", result.stdout)
                self.assertEqual(list(Path(directory).iterdir()), [])
        finally:
            server.shutdown()
            server.server_close()
            thread.join()


if __name__ == "__main__":
    unittest.main()
