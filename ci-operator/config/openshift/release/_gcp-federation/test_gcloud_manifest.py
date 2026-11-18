"""Offline checks for credential isolation and standard AWS metadata loading."""

from datetime import datetime, timezone
from http.server import HTTPServer
import json
from types import SimpleNamespace
import threading
import unittest
from urllib.parse import unquote

from google.auth import load_credentials_from_dict
from google.auth.transport.requests import Request

from gcloud_bridge import Handler
from gcloud_manifest import manifest


class FakeCredentials:
    _expiry_time = datetime(2030, 1, 1, tzinfo=timezone.utc)

    def __init__(self):
        self.generation = 0

    def get_frozen_credentials(self):
        self.generation += 1
        return SimpleNamespace(access_key="TEST-ACCESS-" + str(self.generation), secret_key="test-secret", token="TEST-SESSION-" + str(self.generation))


class FakeSession:
    def __init__(self):
        self.credentials = FakeCredentials()

    def get_credentials(self):
        return self.credentials


class GcloudHarnessTests(unittest.TestCase):
    def test_manifest_isolates_projected_token_and_forbids_static_key_mounts(self):
        config, job = manifest("ci-op-test", "gcloud-test")["items"]
        pod = job["spec"]["template"]["spec"]
        self.assertFalse(pod["automountServiceAccountToken"])
        self.assertFalse(any("secret" in volume for volume in pod["volumes"]))
        self.assertNotIn("aws-token", [volume["name"] for volume in pod["containers"][0]["volumeMounts"]])
        self.assertIn("aws-token", [volume["name"] for volume in pod["initContainers"][0]["volumeMounts"]])
        self.assertNotIn("ci-step-runner-gcp-broker", config["data"]["aws-config"])
        self.assertEqual(pod["initContainers"][0]["restartPolicy"], "Always")
        credentials = json.loads(config["data"]["gcp-creds.json"])
        self.assertEqual(credentials["type"], "external_account")
        self.assertNotIn("private_key", credentials)
        self.assertEqual(credentials["credential_source"]["url"], "http://127.0.0.1:8085/security-credentials")

    def test_standard_google_loader_retrieves_fresh_aws_credentials(self):
        server = HTTPServer(("127.0.0.1", 0), Handler)
        server.aws = FakeSession()
        thread = threading.Thread(target=server.serve_forever, daemon=True)
        thread.start()
        try:
            config = json.loads(manifest("ci-op-test", "gcloud-test")["items"][0]["data"]["gcp-creds.json"])
            config.pop("service_account_impersonation_url")
            base = "http://127.0.0.1:" + str(server.server_port)
            config["credential_source"].update(region_url=base + "/region", url=base + "/security-credentials")
            credentials, _ = load_credentials_from_dict(config)
            first = json.loads(unquote(credentials.retrieve_subject_token(Request())))
            second = json.loads(unquote(credentials.retrieve_subject_token(Request())))
            for subject, generation in [(first, 1), (second, 2)]:
                headers = {h["key"].lower(): h["value"] for h in subject["headers"]}
                self.assertIn("TEST-ACCESS-" + str(generation), headers["authorization"])
                self.assertEqual(headers["x-amz-security-token"], "TEST-SESSION-" + str(generation))
                self.assertEqual(headers["x-goog-cloud-target-resource"], config["audience"])
                self.assertEqual(subject["method"], "POST")
        finally:
            server.shutdown()
            server.server_close()
            thread.join()


if __name__ == "__main__":
    unittest.main()
