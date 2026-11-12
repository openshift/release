"""Offline checks for credential isolation and unambiguous negative-test results."""

import contextlib
import io
import base64
import importlib.util
import json
import tempfile
import unittest
from unittest.mock import MagicMock, patch
from pathlib import Path
from types import SimpleNamespace
from urllib.parse import unquote, urlparse, parse_qs

spec = importlib.util.spec_from_file_location("diagnostic", Path(__file__).with_name("diagnostic.py"))
diagnostic = importlib.util.module_from_spec(spec)
spec.loader.exec_module(diagnostic)


class RotatingCredentials:
    """Model a provider that returns a new coherent credential generation."""

    def __init__(self, method):
        """Initialize a fake provider with a generation counter."""
        self.method = method
        self.calls = 0

    def get_frozen_credentials(self):
        """Return a new fake temporary credential generation."""
        self.calls += 1
        return SimpleNamespace(access_key=str(self.calls), secret_key="secret", token="token")


class Session:
    """Provide only the credential interface required by the supplier."""

    def __init__(self, profile, credentials):
        """Store the fake profile and credential provider."""
        self.profile_name = profile
        self.credentials = credentials

    def get_credentials(self):
        """Return the fake credential provider."""
        return self.credentials


class DiagnosticTests(unittest.TestCase):
    """Exercise authentication checks without cloud calls or real credentials."""

    def test_validate_aws_config(self):
        """Accept the expected role chain and reject bypasses or extra providers."""
        with tempfile.TemporaryDirectory() as directory:
            token = Path(directory, "token")
            token.write_text("not-a-real-token")
            path = Path(directory, "config")
            content = (
                f"[profile home]\nrole_arn={diagnostic.HOME_ARN}\nweb_identity_token_file={token}\n"
                f"[profile hub]\nrole_arn={diagnostic.HUB_ARN}\nsource_profile=home\n"
                f"[default]\nrole_arn={diagnostic.BROKER_ARN}\nsource_profile=hub\n"
            )
            cases = [
                ("generated chain", content, False),
                ("different home", content.replace(diagnostic.HOME_ARN, diagnostic.HUB_ARN), True),
                ("different hub", content.replace(diagnostic.HUB_ARN, diagnostic.BROKER_ARN), True),
                ("different broker", content.replace(diagnostic.BROKER_ARN, diagnostic.HOME_ARN), True),
                ("bypass hub", content.replace("source_profile=hub", "source_profile=home"), True),
                ("static key", content + "aws_access_key_id=key\n", True),
                ("credential process", content + "credential_process=other\n", True),
                ("extra profile", content + "[profile other]\n", True),
            ]
            for name, text, failure in cases:
                with self.subTest(name=name):
                    path.write_text(text)
                    if failure:
                        with self.assertRaises(diagnostic.DiagnosticError):
                            diagnostic.validate_aws_config(path, token)
                    else:
                        diagnostic.validate_aws_config(path, token)


    def test_validate_claims(self):
        """Check expected routing claims and reject mismatched token metadata."""
        valid = {"iss": diagnostic.ISSUER, "aud": ["sts.amazonaws.com"],
                 "sub": "system:serviceaccount:ci-op-example:default", "iat": 1, "exp": 3601}
        cases = [
            ("expected routing", {}, False),
            ("other issuer", {"iss": "https://other.example"}, True),
            ("default API audience", {"aud": ["https://kubernetes.default.svc"]}, True),
            ("additional audience", {"aud": ["sts.amazonaws.com", "other"]}, True),
            ("wrong namespace", {"sub": "system:serviceaccount:default:default"}, True),
            ("missing expiry", {"exp": None}, True),
        ]
        for name, changes, failure in cases:
            with self.subTest(name=name):
                claims = {**valid, **changes}
                if failure:
                    with self.assertRaises(diagnostic.DiagnosticError):
                        diagnostic.validate_claims(claims)
                else:
                    diagnostic.validate_claims(claims)

    def test_get_aws_security_credentials(self):
        """Check coherent rotations and reject unintended credential providers."""
        cases = [
            ("broker", "default", "assume-role", False),
            ("hub", "hub", "assume-role", False),
            ("static fallback", "default", "shared-credentials-file", True),
            ("unintended home provider", "home", "assume-role-with-web-identity", True),
        ]
        for name, profile, method, failure in cases:
            with self.subTest(name=name):
                supplier = diagnostic.ChainSupplier(Session(profile, RotatingCredentials(method)))
                if failure:
                    with self.assertRaises(diagnostic.DiagnosticError):
                        supplier.get_aws_security_credentials(None, None)
                else:
                    first = supplier.get_aws_security_credentials(None, None)
                    second = supplier.get_aws_security_credentials(None, None)
                    self.assertEqual((first.access_key_id, second.access_key_id), ("1", "2"))
                    self.assertEqual(supplier.generations, 2)

    def test_is_condition_rejection(self):
        """Distinguish provider-condition rejection from other HTTP outcomes."""
        payload = {"error": "invalid_grant", "error_description": "The given credential is rejected by the attribute condition."}
        cases = [
            ("provider condition", 400, payload, True),
            ("wrong HTTP status", 403, payload, False),
            ("invalid audience", 400, {"error": "invalid_grant", "error_description": "Invalid audience"}, False),
            ("server error", 500, payload, False),
            ("unexpected success", 200, {"access_token": "not-a-real-token"}, False),
        ]
        for name, status, body, expected in cases:
            with self.subTest(name=name):
                self.assertEqual(diagnostic.is_condition_rejection(status, body), expected)

    def test_subject_token(self):
        """Verify audience signing and credential cloning across fake rotations."""
        supplier = diagnostic.ChainSupplier(Session("default", RotatingCredentials("assume-role")))
        credentials = diagnostic.AudienceBoundCredentials(
            audience=diagnostic.AUDIENCE, subject_token_type=diagnostic.TOKEN_TYPE,
            aws_security_credentials_supplier=supplier, scopes=[diagnostic.SCOPE],
        )
        credentials = credentials.with_scopes([diagnostic.SCOPE])
        for generation in [1, 2]:
            with self.subTest(generation=generation):
                signed = json.loads(unquote(credentials.retrieve_subject_token(diagnostic.Request())))
                url = urlparse(signed["url"])
                self.assertEqual(url.hostname, "sts.us-east-1.amazonaws.com")
                self.assertEqual(parse_qs(url.query)["Action"], ["GetCallerIdentity"])
                headers = {h["key"].lower(): h["value"] for h in signed["headers"]}
                self.assertEqual(headers["x-goog-cloud-target-resource"], diagnostic.AUDIENCE)
                self.assertIn("x-goog-cloud-target-resource", headers["authorization"].split("SignedHeaders=")[1])
                self.assertIn("Credential=" + str(generation) + "/", headers["authorization"])
        self.assertEqual(supplier.generations, 2)

    def test_verify_marker(self):
        """Require the exact marker content and a successful HTTP response."""
        cases = [
            ("expected content", 200, b"OpenShift CI AWS-to-GCP federation pilot\n", False),
            ("changed content", 200, b"different", True),
            ("missing object", 404, b"", True),
            ("access denied", 403, b"", True),
        ]
        for name, status, content, failure in cases:
            with self.subTest(name=name):
                response = SimpleNamespace(status_code=status, content=content)
                if failure:
                    with self.assertRaises(diagnostic.DiagnosticError):
                        diagnostic.verify_marker(response)
                else:
                    diagnostic.verify_marker(response)

    def test_run_renewal_and_log_output(self):
        """Count real token changes while excluding identity and credential data from logs."""
        claims = {"iss": diagnostic.ISSUER, "sub": "system:serviceaccount:ci-op-private:default"}
        payload = base64.urlsafe_b64encode(json.dumps(claims).encode()).decode().rstrip("=")
        token_file = MagicMock()
        token_file.read_text.return_value = "header." + payload + ".signature"
        credentials = SimpleNamespace(token=None)
        supplier = SimpleNamespace(calls=2, generations=2)
        tokens = iter(["fake-token-one", "fake-token-one", "fake-token-two"])
        http = MagicMock()

        def response(url, **kwargs):
            """Refresh fake credentials only on marker reads; deny other requests."""
            if url.endswith("/federation-pilot.txt"):
                credentials.token = next(tokens)
                return SimpleNamespace(status_code=200, content=b"OpenShift CI AWS-to-GCP federation pilot\n")
            return SimpleNamespace(status_code=403)

        http.get.side_effect = response
        output = io.StringIO()
        with contextlib.ExitStack() as stack:
            for name in ["validate_aws_config", "validate_claims",
                         "isolate_environment", "check_provider_rejection"]:
                stack.enter_context(patch.object(diagnostic, name))
            stack.enter_context(patch.object(diagnostic, "TOKEN_PATH", token_file))
            stack.enter_context(patch.object(diagnostic.boto3, "Session"))
            stack.enter_context(patch.object(diagnostic, "ChainSupplier", return_value=supplier))
            stack.enter_context(patch.object(diagnostic, "AudienceBoundCredentials", return_value=credentials))
            stack.enter_context(patch.object(diagnostic, "check_identity", return_value="private-session-arn"))
            stack.enter_context(patch.object(diagnostic, "AuthorizedSession")).return_value.__enter__.return_value = http
            stack.enter_context(patch.object(diagnostic.time, "monotonic", side_effect=[0, 0, 1, 2, 2]))
            stack.enter_context(patch.object(diagnostic.time, "sleep"))
            compare = stack.enter_context(patch.object(diagnostic.hmac, "compare_digest", wraps=diagnostic.hmac.compare_digest))
            stack.enter_context(contextlib.redirect_stdout(output))
            diagnostic.run(2)
        self.assertEqual(compare.call_count, 2)
        rows = [json.loads(line) for line in output.getvalue().splitlines()]
        reads = [row for row in rows if row["check"] == "marker-read"]
        self.assertEqual([row["google_generations"] for row in reads], [1, 1, 2])
        self.assertEqual(rows[-1]["result"], "PASS")
        for row in rows:
            self.assertFalse({"issuer", "subject", "aws_arn", "configured_service_account"} & row.keys())
            for key, value in row.items():
                if key not in {"time", "check", "result"}:
                    self.assertIsInstance(value, (int, float))
        for private in [diagnostic.ISSUER, claims["sub"], diagnostic.SERVICE_ACCOUNT,
                        "private-session-arn", "fake-token-one", "fake-token-two"]:
            self.assertNotIn(private, output.getvalue())

    def test_require_denied(self):
        """Accept only an explicit authorization denial."""
        for status in [200, 400, 403, 404, 500]:
            with self.subTest(status=status):
                response = SimpleNamespace(status_code=status)
                if status == 403:
                    diagnostic.require_denied(response)
                else:
                    with self.assertRaises(diagnostic.DiagnosticError):
                        diagnostic.require_denied(response)


if __name__ == "__main__":
    unittest.main()
