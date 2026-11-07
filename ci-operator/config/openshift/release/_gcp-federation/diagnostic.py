#!/usr/bin/env python3
"""Exercise the isolated build07 AWS-to-GCP pilot without stored cloud keys."""

import argparse
import base64
import configparser
import hashlib
import hmac
import json
import os
import re
import sys
import time
from datetime import datetime, timezone
from pathlib import Path
from urllib.parse import quote

import boto3
import requests
from botocore.config import Config
from google.auth import aws
from google.auth.transport.requests import AuthorizedSession, Request


HOME_ARN = "arn:aws:iam::891612575819:role/ci-step-runner"
HUB_ARN = "arn:aws:iam::320297955214:role/ci-step-runner-hub"
BROKER_ARN = "arn:aws:iam::320297955214:role/ci-step-runner-gcp-broker"
ISSUER = "https://ccoctl-build07-oidc.s3.us-east-1.amazonaws.com"
TOKEN_PATH = Path("/var/run/secrets/aws/sts-token/token")
CONFIG_PATH = Path("/var/run/secrets/aws/config/config")
AUDIENCE = (
    "//iam.googleapis.com/projects/263120870185/locations/global/"
    "workloadIdentityPools/ci-aws-pilot/providers/aws-broker"
)
SERVICE_ACCOUNT = "ci-aws-wif-pilot@openshift-ci-build-farm.iam.gserviceaccount.com"
BUCKET = "openshift-ci-build-farm-aws-wif-pilot-20261104-nr"
MARKER_SHA256 = "8db3eeff8275a7c4d172305c12070eca247dd90fb58a668961a953018abeb695"
STORAGE_URL = "https://storage.googleapis.com/storage/v1/b/" + BUCKET
TOKEN_TYPE = "urn:ietf:params:aws:token-type:aws4_request"
SCOPE = "https://www.googleapis.com/auth/devstorage.read_only"


class DiagnosticError(Exception):
    """Report a controlled failure without including credentials or auth bodies."""


def report(check, result, **fields):
    """Emit fixed status messages and numeric evidence without identity details."""
    print(json.dumps({
        "time": datetime.now(timezone.utc).isoformat(),
        "check": check, "result": result, **fields,
    }), flush=True)


def validate_aws_config(path, token_path=TOKEN_PATH):
    """Require the exact generated home/hub/broker chain with no extra providers."""
    config = configparser.ConfigParser(interpolation=None)
    if not config.read(path):
        raise DiagnosticError("generated AWS config is missing")
    expected = {
        "profile home": {"role_arn": HOME_ARN, "web_identity_token_file": str(token_path)},
        "profile hub": {"role_arn": HUB_ARN, "source_profile": "home"},
        "default": {"role_arn": BROKER_ARN, "source_profile": "hub"},
    }
    if config.defaults() or set(config.sections()) != set(expected):
        raise DiagnosticError("unexpected AWS config sections")
    for section, values in expected.items():
        if dict(config[section]) != values:
            raise DiagnosticError("unexpected AWS config values")
    if not token_path.is_file():
        raise DiagnosticError("projected AWS token is missing")


def validate_profile(path):
    """Reject profile files other than the two role identifiers."""
    fields = {p.name for p in path.iterdir() if not p.name.startswith("..")}
    if fields != {"hub_role_arn", "target_role_arn"}:
        raise DiagnosticError("cluster profile contains unexpected fields")
    if (path / "hub_role_arn").read_text().strip() != HUB_ARN:
        raise DiagnosticError("profile hub ARN differs")
    if (path / "target_role_arn").read_text().strip() != BROKER_ARN:
        raise DiagnosticError("profile broker ARN differs")


def validate_claims(claims):
    """Check token routing metadata; AWS performs the actual signature verification."""
    audiences = claims.get("aud", [])
    if isinstance(audiences, str):
        audiences = [audiences]
    if claims.get("iss") != ISSUER or audiences != ["sts.amazonaws.com"]:
        raise DiagnosticError("unexpected token issuer or audience")
    if not re.fullmatch(r"system:serviceaccount:ci-op-[^:]+:[^:]+", claims.get("sub", "")):
        raise DiagnosticError("unexpected token subject")
    if not isinstance(claims.get("iat"), int) or not isinstance(claims.get("exp"), int):
        raise DiagnosticError("token lifetime metadata is missing")


def isolate_environment():
    """Disable alternative AWS credential sources before constructing SDK sessions."""
    for name in ["AWS_ACCESS_KEY_ID", "AWS_SECRET_ACCESS_KEY", "AWS_SESSION_TOKEN", "AWS_SECURITY_TOKEN"]:
        if os.environ.get(name):
            raise DiagnosticError("static AWS credential environment is present")
    for name in list(os.environ):
        if name.startswith(("AWS_", "GOOGLE_")):
            del os.environ[name]
    os.environ.update({
        "AWS_CONFIG_FILE": str(CONFIG_PATH),
        "AWS_SHARED_CREDENTIALS_FILE": "/dev/null",
        "AWS_EC2_METADATA_DISABLED": "true",
        "AWS_STS_REGIONAL_ENDPOINTS": "regional",
        "AWS_IGNORE_CONFIGURED_ENDPOINT_URLS": "true",
    })


class ChainSupplier(aws.AwsSecurityCredentialsSupplier):
    """Read coherent refreshable AWS snapshots for each Google exchange."""

    def __init__(self, session):
        """Track credential generations supplied by the refreshable session."""
        self.session = session
        self.calls = 0
        self.generations = 0
        self.last_access_key = None

    def get_aws_region(self, context, request):
        """Return the fixed region used to sign pilot STS requests."""
        return "us-east-1"

    def get_aws_security_credentials(self, context, request):
        """Return one coherent temporary credential snapshot and count rotations."""
        credentials = self.session.get_credentials()
        if credentials is None or credentials.method != "assume-role":
            raise DiagnosticError("AWS credentials did not use the expected role provider")
        frozen = credentials.get_frozen_credentials()
        if not frozen.token:
            raise DiagnosticError("AWS credentials lack a session token")
        self.calls += 1
        if frozen.access_key != self.last_access_key:
            self.last_access_key = frozen.access_key
            self.generations += 1
        return aws.AwsSecurityCredentials(frozen.access_key, frozen.secret_key, frozen.token)


class AudienceBoundCredentials(aws.Credentials):
    """Use the public AWS signer to include the provider audience in the signature."""

    def __init__(self, audience, subject_token_type, aws_security_credentials_supplier, **kwargs):
        """Retain the audience and supplier for signing and SDK credential cloning."""
        self.signing_audience = audience
        self.supplier = aws_security_credentials_supplier
        super().__init__(
            audience=audience, subject_token_type=subject_token_type,
            aws_security_credentials_supplier=aws_security_credentials_supplier, **kwargs,
        )

    def retrieve_subject_token(self, request):
        """Serialize a signed AWS identity request bound to the provider audience."""
        region = self.supplier.get_aws_region(None, request)
        credentials = self.supplier.get_aws_security_credentials(None, request)
        options = aws.RequestSigner(region).get_request_options(
            credentials,
            f"https://sts.{region}.amazonaws.com?Action=GetCallerIdentity&Version=2011-06-15",
            "POST", additional_headers={"x-goog-cloud-target-resource": self.signing_audience},
        )
        signed = {
            "url": options["url"], "method": options["method"],
            "headers": [{"key": key, "value": value} for key, value in options["headers"].items()],
        }
        return quote(json.dumps(signed, separators=(",", ":"), sort_keys=True))


def check_identity(session, role_arn):
    """Verify the actual assumed role before using it in a Google exchange."""
    client = session.client("sts", config=Config(
        connect_timeout=10, read_timeout=20, retries={"max_attempts": 2},
    ))
    identity = client.get_caller_identity()
    prefix = role_arn.replace(":iam:", ":sts:").replace(":role/", ":assumed-role/") + "/"
    if not identity["Arn"].startswith(prefix):
        raise DiagnosticError("unexpected AWS caller identity")
    return identity["Arn"]


def is_condition_rejection(status, payload):
    """Distinguish provider admission rejection from unrelated authentication failures."""
    return (
        status == 400
        and payload.get("error") == "invalid_grant"
        and "attribute condition" in payload.get("error_description", "").lower()
    )


def check_provider_rejection(profile, role_arn):
    """Require Google STS to reject a real hub role at the provider condition."""
    session = boto3.Session(profile_name=profile, region_name="us-east-1")
    check_identity(session, role_arn)
    credentials = AudienceBoundCredentials(
        audience=AUDIENCE, subject_token_type=TOKEN_TYPE,
        aws_security_credentials_supplier=ChainSupplier(session), scopes=[SCOPE],
    )
    with requests.Session() as http:
        subject_token = credentials.retrieve_subject_token(Request(session=http))
        response = http.post("https://sts.googleapis.com/v1/token", timeout=30, data={
            "grant_type": "urn:ietf:params:oauth:grant-type:token-exchange",
            "requested_token_type": "urn:ietf:params:oauth:token-type:access_token",
            "subject_token_type": TOKEN_TYPE, "subject_token": subject_token,
            "audience": AUDIENCE, "scope": SCOPE,
        }, allow_redirects=False)
        if not is_condition_rejection(response.status_code, response.json()):
            raise DiagnosticError("Google STS did not reject the unauthorized role at its condition")
    report("provider-rejection", "PASS")


def verify_marker(response):
    """Require successful access to the exact expected harmless object content."""
    if response.status_code != 200:
        raise DiagnosticError("marker read did not succeed")
    if hashlib.sha256(response.content).hexdigest() != MARKER_SHA256:
        raise DiagnosticError("marker SHA256 differs from expected")


def require_denied(response):
    """Require an authorization denial, not an absent object or network error."""
    if response.status_code != 403:
        raise DiagnosticError("expected authorization denial")


def run(duration):
    """Run positive, provider rejection, storage denial and optional renewal checks."""
    validate_profile(Path(os.environ["CLUSTER_PROFILE_DIR"]))
    validate_aws_config(CONFIG_PATH)
    payload = TOKEN_PATH.read_text().split(".")[1]
    claims = json.loads(base64.urlsafe_b64decode(payload + "=" * (-len(payload) % 4)))
    validate_claims(claims)
    report("projected-token-routing", "PASS")
    isolate_environment()
    report("service-account-review", "PENDING")
    session = boto3.Session(profile_name="default", region_name="us-east-1")
    supplier = ChainSupplier(session)
    credentials = AudienceBoundCredentials(
        audience=AUDIENCE, subject_token_type=TOKEN_TYPE,
        aws_security_credentials_supplier=supplier, scopes=[SCOPE],
        service_account_impersonation_url=(
            "https://iamcredentials.googleapis.com/v1/projects/-/serviceAccounts/"
            + SERVICE_ACCOUNT + ":generateAccessToken"
        ),
    )
    start = time.monotonic()
    last_google_token = None
    google_generations = 0
    first_read = True
    with AuthorizedSession(credentials) as http:
        while True:
            check_identity(session, BROKER_ARN)
            verify_marker(http.get(STORAGE_URL + "/o/federation-pilot.txt", params={"alt": "media"},
                                   timeout=30, allow_redirects=False))
            if last_google_token is None or not hmac.compare_digest(credentials.token, last_google_token):
                google_generations += 1
                last_google_token = credentials.token
            elapsed = time.monotonic() - start
            report("marker-read", "PASS", elapsed_seconds=round(elapsed),
                   google_generations=google_generations, supplier_calls=supplier.calls,
                   aws_generations_supplied=supplier.generations)
            if first_read:
                # Run admission and storage denial checks once, after the initial successful read.
                require_denied(http.get(STORAGE_URL + "/o/denied-control.txt", params={"alt": "media"},
                                        timeout=30, allow_redirects=False))
                require_denied(http.get(STORAGE_URL + "/o", params={"maxResults": 1},
                                        timeout=30, allow_redirects=False))
                report("storage-denial", "PASS")
                check_provider_rejection("hub", HUB_ARN)
                first_read = False
            if elapsed >= duration:
                break
            time.sleep(min(60, max(0, duration - elapsed)))
    if duration and (google_generations < 2 or supplier.generations < 2):
        raise DiagnosticError("renewal observation incomplete")
    report("diagnostic", "PASS", renewal_observed=bool(duration), elapsed_seconds=round(time.monotonic() - start))


if __name__ == "__main__":
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--duration-seconds", type=int, choices=[0, 4500], default=0)
    arguments = parser.parse_args()
    try:
        run(arguments.duration_seconds)
    except DiagnosticError as error:
        report("diagnostic", "FAIL", error=str(error))
        sys.exit(1)
    except Exception as error:
        # OAuth and SDK error text can include signed requests. Never print it.
        report("diagnostic", "FAIL", error_type=type(error).__name__)
        sys.exit(1)
