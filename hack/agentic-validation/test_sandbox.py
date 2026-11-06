"""Broker behavior without requiring containers, credentials or a live cluster."""

from pathlib import Path
import os
import shlex
import socket
import socketserver
import tempfile
import threading
import unittest
from unittest import mock

import sandbox


class BrokerTests(unittest.TestCase):
    def test_broker_rejects_other_destinations_and_methods(self):
        with tempfile.TemporaryDirectory() as temporary:
            path = Path(temporary) / "api.sock"
            with mock.patch.object(socket, "getaddrinfo", return_value=[]):
                proxy = sandbox.APIProxy(path, "https://api.cluster.example:6443")
            thread = threading.Thread(target=proxy.serve_forever, daemon=True)
            thread.start()
            try:
                requests = [
                    b"CONNECT build-farm.example:6443 HTTP/1.1\r\n\r\n",
                    b"CONNECT api.cluster.example:443 HTTP/1.1\r\n\r\n",
                    b"GET https://api.cluster.example:6443/ HTTP/1.1\r\n\r\n",
                ]
                for request in requests:
                    with self.subTest(request=request):
                        with socket.socket(socket.AF_UNIX, socket.SOCK_STREAM) as client:
                            client.settimeout(2)
                            client.connect(str(path))
                            client.sendall(request)
                            self.assertIn(b"403 Forbidden", client.recv(1024))
                with socket.socket(socket.AF_UNIX, socket.SOCK_STREAM) as client:
                    client.settimeout(2)
                    client.connect(str(path))
                    client.sendall(b"CONNECT api.cluster.example:6443 HTTP/1.1\r\n\r\n")
                    self.assertIn(b"502 Bad Gateway", client.recv(1024))
            finally:
                proxy.shutdown()
                thread.join(timeout=5)
                proxy.server_close()


class EchoHandler(socketserver.BaseRequestHandler):
    def handle(self):
        self.request.sendall(self.request.recv(1024))


@unittest.skipUnless(os.environ.get("VALIDATION_SANDBOX_TEST_IMAGE"), "set VALIDATION_SANDBOX_TEST_IMAGE for the container smoke test")
class ContainerTests(unittest.TestCase):
    def test_networkless_container_uses_only_api_broker(self):
        with tempfile.TemporaryDirectory() as temporary, socketserver.TCPServer(("127.0.0.1", 0), EchoHandler) as upstream:
            thread = threading.Thread(target=upstream.serve_forever, daemon=True)
            thread.start()
            try:
                directory = Path(temporary)
                (directory / "kubeconfig.json").write_text('{"dummy":true}')
                port = upstream.server_address[1]
                with mock.patch.dict(os.environ, {"VALIDATION_SANDBOX_IMAGE": os.environ["VALIDATION_SANDBOX_TEST_IMAGE"]}):
                    with sandbox.Sandbox(directory, f"https://127.0.0.1:{port}") as container:
                        probe = "import socket; s=socket.socket(socket.AF_UNIX); s.settimeout(2); s.connect('/broker/api.sock'); s.close()"
                        output, status = container.run("python3 -c " + shlex.quote(probe))
                        self.assertEqual(status, 0, output)
                        script = (
                            "import socket,time\n"
                            "for attempt in range(30):\n"
                            " try:\n"
                            "  proxy=socket.create_connection(('127.0.0.1',18080),timeout=2); break\n"
                            " except OSError: time.sleep(0.1)\n"
                            f"proxy.sendall(b'CONNECT 127.0.0.1:{port} HTTP/1.1\\r\\n\\r\\n')\n"
                            "header=b''\n"
                            "while not header.endswith(b'\\r\\n\\r\\n'):\n"
                            " chunk=proxy.recv(1); assert chunk,'relay closed before CONNECT response'; header+=chunk\n"
                            "assert b'200 Connection Established' in header,header\n"
                            "proxy.sendall(b'api-evidence'); assert proxy.recv(1024)==b'api-evidence'\n"
                            "proxy.close()\n"
                            "external=socket.socket(); external.settimeout(1)\n"
                            "assert external.connect_ex(('1.1.1.1',443))!=0\n"
                            "print('broker reached target; direct network blocked')\n"
                        )
                        output, status = container.run("python3 -c " + shlex.quote(script))
                        self.assertEqual(status, 0, output)
                        self.assertIn("direct network blocked", output)
                        output, status = container.run("test -z \"$(ls -A /run/secrets)\" && test ! -e /var/run/validation-model && test ! -e /var/run/jira-token && test ! -e /run/podman/podman.sock && touch /work/fixture && test -f /work/fixture")
                        self.assertEqual(status, 0, output)
            finally:
                upstream.shutdown()
                thread.join(timeout=5)


if __name__ == "__main__":
    unittest.main()
