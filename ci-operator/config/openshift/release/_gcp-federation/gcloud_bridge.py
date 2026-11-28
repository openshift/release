"""Expose refreshable AWS hub credentials only on this test pod's loopback."""

import json
import os
from http.server import BaseHTTPRequestHandler, HTTPServer

import boto3
from botocore.config import Config


class Handler(BaseHTTPRequestHandler):
    """Serve the AWS metadata shape expected by standard Google clients."""

    def log_message(self, format, *args):
        # Never log credential responses or authentication request details.
        pass

    def do_GET(self):
        payload = b"ok"
        content_type = "text/plain"
        if self.path == "/region":
            payload = b"us-east-1a"
        elif self.path == "/security-credentials":
            payload = b"ci-hub"
        elif self.path == "/security-credentials/ci-hub":
            try:
                credentials = self.server.aws.get_credentials()
                frozen = credentials.get_frozen_credentials()
                if not frozen.token:
                    raise ValueError("temporary credentials required")
                payload = json.dumps({
                    "Code": "Success", "AccessKeyId": frozen.access_key,
                    "SecretAccessKey": frozen.secret_key, "Token": frozen.token,
                    "Expiration": credentials._expiry_time.isoformat(),
                }).encode()
                content_type = "application/json"
            except Exception:
                self.send_error(503, "Temporary credentials unavailable")
                return
        elif self.path != "/healthz":
            self.send_error(404)
            return
        self.send_response(200)
        self.send_header("Content-Type", content_type)
        self.send_header("Cache-Control", "no-store")
        self.send_header("Content-Length", str(len(payload)))
        self.end_headers()
        self.wfile.write(payload)


def main():
    for key in ("AWS_ACCESS_KEY_ID", "AWS_SECRET_ACCESS_KEY", "AWS_SESSION_TOKEN", "AWS_SECURITY_TOKEN"):
        if os.environ.get(key):
            raise ValueError("static AWS environment credentials are forbidden")
    os.environ.update({"AWS_CONFIG_FILE": "/var/run/secrets/aws/config/config", "AWS_SHARED_CREDENTIALS_FILE": "/dev/null", "AWS_EC2_METADATA_DISABLED": "true"})
    session = boto3.Session(profile_name="hub", region_name="us-east-1")
    caller = session.client("sts", config=Config(connect_timeout=10, read_timeout=20)).get_caller_identity()
    if not caller["Arn"].startswith("arn:aws:sts::320297955214:assumed-role/ci-step-runner-hub/"):
        raise ValueError("unexpected AWS identity")
    server = HTTPServer(("127.0.0.1", 8085), Handler)
    server.aws = session
    print(json.dumps({"check": "loopback-hub-bridge", "result": "ready"}), flush=True)
    server.serve_forever()


if __name__ == "__main__":
    try:
        main()
    except Exception as error:
        print(json.dumps({"result": "failed", "error_type": type(error).__name__}), flush=True)
        raise SystemExit(1)
