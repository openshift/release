#!/usr/bin/env python3

import io
import json
from http.server import BaseHTTPRequestHandler, ThreadingHTTPServer
from pathlib import Path
import shutil
import subprocess
import tarfile
import tempfile
import threading
import unittest
from urllib.parse import parse_qs, urlparse

OC = shutil.which("oc")
if OC is not None:
    OC = str(Path(OC).resolve())


def _receive_upload(handler, fixture):
    url = urlparse(handler.path)
    fixture.requests.append(("POST", url.path, parse_qs(url.query)))
    data = bytearray()
    if handler.headers.get("Transfer-Encoding") == "chunked":
        while True:
            length = int(handler.rfile.readline().strip(), 16)
            if not length:
                handler.rfile.readline()
                break
            data.extend(handler.rfile.read(length))
            handler.rfile.read(2)
            if len(data) > 1024 * 1024:
                raise ValueError("unexpected synthetic upload size")
    else:
        data.extend(handler.rfile.read(int(handler.headers.get("Content-Length", "0"))))
    if url.path.endswith("/buildconfigs/usage-exporter/instantiatebinary"):
        with tarfile.open(fileobj=io.BytesIO(data), mode="r:*") as archive:
            fixture.uploads.append([str(Path(name)) for name in archive.getnames() if str(Path(name)) != "."])
        if fixture.responses["scenario"] != "ambiguous":
            handler.reply(fixture.build("Running"), 201)
    else:
        handler.reply({"kind": "Status", "apiVersion": "v1", "status": "Failure", "reason": "Forbidden", "code": 403}, 403)


class EnmaasExporterCliTests(unittest.TestCase):
    def prepare_context(self):
        self.directory = Path(tempfile.mkdtemp(prefix="enmaas cli "))
        self.addCleanup(shutil.rmtree, self.directory)
        self.context = self.directory / "context"
        self.context.mkdir()
        (self.context / "Containerfile").write_text("FROM scratch\nCOPY app.txt /app.txt\n")
        (self.context / "app.txt").write_text("synthetic source\n")
        (self.context / ".git").mkdir()
        (self.context / ".git/config").write_text("synthetic excluded metadata\n")

    def setUp(self):
        self.assertIsNotNone(OC, "real oc is required for exporter CLI contract tests")
        self.prepare_context()
        self.requests = []
        self.uploads = []
        self.responses = {"scenario": "complete", "build_gets": 0, "release_watch": threading.Event()}
        fixture = self

        class Handler(BaseHTTPRequestHandler):
            def log_message(self, *_arguments):
                pass

            def reply(self, document, status=200, content_type="application/json"):
                data = document if isinstance(document, bytes) else json.dumps(document).encode()
                self.send_response(status)
                self.send_header("Content-Type", content_type)
                self.send_header("Content-Length", str(len(data)))
                self.end_headers()
                self.wfile.write(data)

            def do_GET(self):
                url = urlparse(self.path)
                query = parse_qs(url.query)
                fixture.requests.append(("GET", url.path, query))
                if url.path == "/api":
                    self.reply({"kind": "APIVersions", "apiVersion": "v1", "versions": ["v1"]})
                elif url.path == "/apis":
                    self.reply({"kind": "APIGroupList", "apiVersion": "v1", "groups": [{
                        "name": group, "versions": [{"groupVersion": group + "/v1", "version": "v1"}],
                        "preferredVersion": {"groupVersion": group + "/v1", "version": "v1"}}
                        for group in ("build.openshift.io", "image.openshift.io")]})
                elif url.path in ("/api/v1", "/apis/build.openshift.io/v1", "/apis/image.openshift.io/v1"):
                    resources = (["buildconfigs", "builds"] if "build.openshift.io" in url.path else
                                 ["imagestreamimages"] if "image.openshift.io" in url.path else ["secrets", "serviceaccounts"])
                    self.reply({"kind": "APIResourceList", "apiVersion": "v1", "groupVersion": url.path.removeprefix("/apis/").removeprefix("/api/"),
                                "resources": [{"name": name, "kind": {"buildconfigs": "BuildConfig", "builds": "Build",
                                                                      "imagestreamimages": "ImageStreamImage"}.get(name, "Secret"),
                                               "namespaced": True, "verbs": ["get", "list", "watch", "create"]} for name in resources]})
                elif url.path.endswith("/buildconfigs/usage-exporter"):
                    self.reply({"apiVersion": "build.openshift.io/v1", "kind": "BuildConfig",
                                "metadata": {"name": "usage-exporter", "namespace": "enmaas"},
                                "spec": {"source": {"type": "Binary"}, "strategy": {"type": "Docker", "dockerStrategy": {"dockerfilePath": "Containerfile"}}}})
                elif url.path.endswith("/builds/usage-exporter-7/log"):
                    self.reply(b"SYNTHETIC_BUILD_LOG\n", content_type="text/plain")
                elif url.path.endswith("/builds/usage-exporter-7"):
                    fixture.reply_completed_build(self)
                elif "/imagestreamimages/usage-exporter@" in url.path:
                    digest = "sha256:" + ("b" if fixture.responses["scenario"] == "stale-image" else "a") * 64
                    self.reply({"apiVersion": "image.openshift.io/v1", "kind": "ImageStreamImage",
                                "metadata": {"name": "usage-exporter@" + digest, "namespace": "enmaas"},
                                "image": {"metadata": {"name": digest}}})
                elif url.path.endswith("/builds"):
                    if query.get("watch") == ["true"]:
                        if fixture.responses["scenario"] == "timeout":
                            self.send_response(200)
                            self.send_header("Content-Type", "application/json")
                            self.end_headers()
                            fixture.responses["release_watch"].wait(10)
                        else:
                            self.reply(json.dumps({"type": "MODIFIED", "object": fixture.build("Complete")}).encode() + b"\n")
                    else:
                        phase = "Running" if fixture.responses["scenario"] in ("watch", "timeout") else "Failed" if fixture.responses["scenario"] == "failed" else "Complete"
                        self.reply({"apiVersion": "build.openshift.io/v1", "kind": "BuildList", "metadata": {"resourceVersion": "1"},
                                    "items": [fixture.build(phase)]})
                else:
                    self.reply({"kind": "Status", "apiVersion": "v1", "status": "Failure", "reason": "NotFound", "code": 404}, 404)

            def do_POST(self):
                _receive_upload(self, fixture)

        self.server = ThreadingHTTPServer(("127.0.0.1", 0), Handler)
        self.thread = threading.Thread(target=self.server.serve_forever)
        self.thread.start()
        self.addCleanup(self.close_server)

    def close_server(self):
        self.responses["release_watch"].set()
        self.server.shutdown()
        self.server.server_close()
        self.thread.join(timeout=5)
        self.assertFalse(self.thread.is_alive())

    def build(self, phase):
        return {"apiVersion": "build.openshift.io/v1", "kind": "Build",
                "metadata": {"name": "usage-exporter-7", "namespace": "enmaas", "uid": "synthetic-new-build", "resourceVersion": "2"},
                "spec": {"output": {"to": {"kind": "ImageStreamTag", "name": "usage-exporter:latest"}}},
                "status": {"phase": phase, "config": {"name": "usage-exporter"},
                           "output": {"to": {"imageDigest": "sha256:" + "a" * 64}},
                           "outputDockerImageReference": ("example.invalid/other:latest" if self.responses["scenario"] == "wrong-output" else
                                                          "image-registry.openshift-image-registry.svc:5000/enmaas/usage-exporter:latest")}}

    def reply_completed_build(self, handler):
        self.responses["build_gets"] += 1
        if self.responses["scenario"] == "lookup-error":
            handler.reply({"kind": "Status", "apiVersion": "v1", "message": "UNSAFE_SOURCE_OUTPUT", "code": 403}, 403)
            return
        document = self.build("Running" if self.responses["scenario"] == "incomplete" else "Complete")
        if self.responses["scenario"] == "changed-uid" and self.responses["build_gets"] > 1:
            document["metadata"]["uid"] = "different-build"
        if self.responses["scenario"] == "changed-digest" and self.responses["build_gets"] > 1:
            document["status"]["output"]["to"]["imageDigest"] = "sha256:" + "b" * 64
        handler.reply(document)

    def run_cli(self, follow, output="name"):
        return subprocess.run([OC, "--kubeconfig=/dev/null", "--server=http://127.0.0.1:" + str(self.server.server_port),
                               "--request-timeout=5s", "--loglevel=0", "--cache-dir=" + str(self.directory / "cache"),
                               "start-build", "usage-exporter", "--from-dir=" + str(self.context), "-n", "enmaas",
                               "--follow=" + str(follow).lower(), "--wait", "-o", output],
                              env={"PATH": "/usr/local/bin:/usr/bin:/bin", "HOME": str(self.directory)},
                              capture_output=True, text=True, check=False, timeout=15)

    def test_json_output_support_is_detected_without_assuming_it(self):
        result = self.run_cli(False, "json")
        if result.returncode:
            self.assertIn("Unsupported output format", result.stderr)
            self.assertEqual(self.requests, [])
        else:
            self.assertEqual(json.loads(result.stdout)["metadata"]["name"], "usage-exporter-7")

    def test_follow_wait_appends_logs_to_identity(self):
        result = self.run_cli(True)
        self.assertEqual(result.returncode, 0, result.stderr)
        self.assertTrue("SYNTHETIC_BUILD_LOG" in result.stdout)
        self.assertGreater(len(result.stdout.splitlines()), 1)
        self.assertTrue(any(path.endswith("/log") for _, path, _ in self.requests))

    def test_wait_without_follow_preserves_exact_identity_and_upload(self):
        result = self.run_cli(False)
        self.assertEqual(result.returncode, 0, result.stderr)
        self.assertEqual(result.stdout.strip(), "build.build.openshift.io/usage-exporter-7")
        self.assertFalse(any(path.endswith("/log") for _, path, _ in self.requests))
        self.assertEqual(len(self.uploads), 1)
        self.assertEqual(sorted(self.uploads[0]), ["Containerfile", "app.txt"])
        self.assertTrue(any(query.get("fieldSelector") == ["metadata.name=usage-exporter-7"] for _, _, query in self.requests))

    def test_wait_propagates_failed_build(self):
        self.responses["scenario"] = "failed"
        result = self.run_cli(False)
        self.assertNotEqual(result.returncode, 0)

    def test_wait_uses_native_watch_for_running_build(self):
        self.responses["scenario"] = "watch"
        result = self.run_cli(False)
        self.assertEqual(result.returncode, 0, result.stderr)
        self.assertTrue(any(query.get("watch") == ["true"] for _, _, query in self.requests))


if __name__ == "__main__":
    unittest.main()
