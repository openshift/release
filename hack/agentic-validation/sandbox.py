#!/usr/bin/env python3
"""Networkless command container and a CONNECT-only target API broker.

The model and preparation credentials stay in the parent process. The container
has only an embedded target kubeconfig and a Unix socket which can tunnel to one
pre-resolved target API endpoint. Target-cluster workload egress must also be
isolated by the infrastructure running the disposable cluster (see README).
"""

import contextlib
import json
import os
from pathlib import Path
import select
import socket
import socketserver
import subprocess
import sys
import threading
import time
import urllib.parse
import uuid


class SandboxError(Exception):
    """A safe description of a sandbox infrastructure failure."""


def copy_connections(left, right):
    sockets = [left, right]
    while sockets:
        readable, _, _ = select.select(sockets, [], [], 120)
        if not readable:
            return
        for source in readable:
            data = source.recv(65536)
            if not data:
                return
            target = right if source is left else left
            target.sendall(data)


class APIHandler(socketserver.BaseRequestHandler):
    """Accept only CONNECT to the exact configured authority, without DNS reuse."""

    def handle(self):
        self.request.settimeout(120)
        header = bytearray()
        while not header.endswith(b"\r\n\r\n"):
            data = self.request.recv(1)
            if not data or len(header) > 16384:
                return
            header.extend(data)
        line = bytes(header).split(b"\r\n", 1)[0]
        if line != f"CONNECT {self.server.authority} HTTP/1.1".encode():
            self.request.sendall(b"HTTP/1.1 403 Forbidden\r\nContent-Length: 0\r\n\r\n")
            return
        with contextlib.ExitStack() as stack:
            upstream = None
            for family, socktype, protocol, _, address in self.server.addresses:
                candidate = socket.socket(family, socktype, protocol)
                candidate.settimeout(30)
                try:
                    candidate.connect(address)
                    upstream = stack.enter_context(candidate)
                    break
                except OSError:
                    candidate.close()
            if upstream is None:
                self.request.sendall(b"HTTP/1.1 502 Bad Gateway\r\nContent-Length: 0\r\n\r\n")
                return
            self.request.sendall(b"HTTP/1.1 200 Connection Established\r\n\r\n")
            with contextlib.suppress(OSError):
                copy_connections(self.request, upstream)


class APIProxy(socketserver.ThreadingUnixStreamServer):
    daemon_threads = True
    request_queue_size = 16

    def __init__(self, path, target):
        parsed = urllib.parse.urlsplit(target)
        host = parsed.hostname
        port = parsed.port or 443
        authority_host = f"[{host}]" if ":" in host else host
        self.authority = f"{authority_host}:{port}"
        self.addresses = socket.getaddrinfo(host, port, type=socket.SOCK_STREAM)
        self.slots = threading.BoundedSemaphore(16)
        super().__init__(str(path), APIHandler)

    def process_request(self, request, client_address):
        # The worker thread releases this slot after the request finishes.
        if not self.slots.acquire(blocking=False):  # pylint: disable=consider-using-with
            self.shutdown_request(request)
            return
        try:
            super().process_request(request, client_address)
        except BaseException:
            self.slots.release()
            raise

    def process_request_thread(self, request, client_address):
        try:
            super().process_request_thread(request, client_address)
        finally:
            self.slots.release()

    def handle_error(self, request, client_address):
        # Do not dump command requests, addresses or socket details into CI logs.
        return


class RelayHandler(socketserver.BaseRequestHandler):
    def handle(self):
        with socket.socket(socket.AF_UNIX, socket.SOCK_STREAM) as upstream:
            upstream.connect("/broker/api.sock")
            with contextlib.suppress(OSError):
                copy_connections(self.request, upstream)


class RelayServer(socketserver.ThreadingTCPServer):
    allow_reuse_address = True
    daemon_threads = True

    def handle_error(self, request, client_address):
        return


def relay():
    with RelayServer(("127.0.0.1", 18080), RelayHandler) as server:
        server.serve_forever()


def podman(args, timeout=120):
    result = subprocess.run(["podman", *args], capture_output=True, timeout=timeout, check=False)
    if result.returncode:
        raise SandboxError(f"sandbox podman operation failed (status {result.returncode})")
    return result.stdout.decode("utf-8", errors="replace")


class Sandbox:
    def __init__(self, directory, target):
        self.directory = Path(directory)
        self.target = target
        self.name = "agent-validation-" + uuid.uuid4().hex
        self.proxy = None
        self.thread = None
        self.started = False

    def __enter__(self):
        try:
            image = os.environ.get("VALIDATION_SANDBOX_IMAGE", "")
            if not image or any(character.isspace() for character in image) or image.startswith("-"):
                raise SandboxError("VALIDATION_SANDBOX_IMAGE must identify the runner image")
            exists = subprocess.run(["podman", "image", "exists", image], capture_output=True, check=False, timeout=30)
            if exists.returncode:
                podman(["pull", "--quiet", image], timeout=300)
            # Resolve once, then run by immutable local image ID.
            image_id = json.loads(podman(["image", "inspect", image]))[0]["Id"]
            broker = self.directory / "broker"
            broker.mkdir(mode=0o700)
            self.proxy = APIProxy(broker / "api.sock", self.target)
            self.thread = threading.Thread(target=self.proxy.serve_forever, daemon=True)
            self.thread.start()
            podman(["run", "--detach", "--name", self.name, "--pull=never", "--network=none",
                    "--http-proxy=false", "--read-only", "--cap-drop=ALL",
                    # The Unix broker belongs to the supervisor's process label.
                    # Mount/network namespaces, capabilities and seccomp remain.
                    "--security-opt=label=disable", "--security-opt=no-new-privileges",
                    "--pids-limit=128", "--memory=1g", "--cpus=1",
                    "--tmpfs=/work:rw,size=268435456", "--tmpfs=/tmp:rw,size=67108864",
                    # Hide any subscription credentials injected by mounts.conf.
                    "--tmpfs=/run/secrets:rw,noexec,nosuid,nodev,size=1048576",
                    "--volume", f"{broker}:/broker:ro,z",
                    "--volume", f"{self.directory / 'kubeconfig.json'}:/kubeconfig:ro,Z",
                    "--workdir=/work", "--env=HOME=/work", "--env=KUBECONFIG=/kubeconfig",
                    "--env=HTTPS_PROXY=http://127.0.0.1:18080", "--env=https_proxy=http://127.0.0.1:18080",
                    "--env=HTTP_PROXY=http://127.0.0.1:18080", "--env=http_proxy=http://127.0.0.1:18080",
                    "--env=NO_PROXY=", "--env=no_proxy=", "--entrypoint=/usr/bin/python3",
                    image_id, "/opt/agentic-validation/sandbox.py", "relay"])
            self.started = True
            _, status = self.run("test -r /kubeconfig && test -S /broker/api.sock && command -v oc >/dev/null")
            if status:
                raise SandboxError("sandbox preflight failed")
            return self
        except BaseException:
            self.__exit__(None, None, None)
            raise

    def run(self, text):
        # Bound both memory and host disk use, including malicious output floods.
        with subprocess.Popen(["podman", "exec", self.name, "bash", "-c", text],
                              stdout=subprocess.PIPE, stderr=subprocess.STDOUT) as process:
            deadline = time.monotonic() + 90
            output = bytearray()
            try:
                while True:
                    remaining = deadline - time.monotonic()
                    if remaining <= 0:
                        raise subprocess.TimeoutExpired("sandbox command", 90)
                    readable, _, _ = select.select([process.stdout], [], [], remaining)
                    if not readable:
                        raise subprocess.TimeoutExpired("sandbox command", 90)
                    data = os.read(process.stdout.fileno(), 65536)
                    if not data:
                        break
                    output.extend(data)
                    if len(output) > 65536:
                        raise SandboxError("sandbox output limit exceeded; observation incomplete")
                status = process.wait(timeout=max(0.01, deadline - time.monotonic()))
                return output.decode("utf-8", errors="replace"), status
            except BaseException:
                # Killing only the client leaves the command alive in-container.
                self.stop()
                process.kill()
                process.wait(timeout=10)
                raise

    def stop(self):
        with contextlib.suppress(OSError, subprocess.SubprocessError, SandboxError):
            podman(["rm", "--force", "--time=5", self.name], timeout=15)
        self.started = False

    def __exit__(self, exc_type, exc_value, traceback):
        self.stop()
        if self.proxy:
            if self.thread:
                self.proxy.shutdown()
                self.thread.join(timeout=5)
            self.proxy.server_close()


if __name__ == "__main__" and sys.argv[1:] == ["relay"]:
    relay()
