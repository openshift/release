"""Run isolated authorization and renewal checks without printing credentials."""

import hashlib
import json
import os
import sys
import time
from datetime import datetime, timezone
from pathlib import Path
from urllib.parse import quote

sys.path.insert(0, os.path.join(os.environ["GOOGLE_SDK_ROOT"], "lib", "third_party"))
from google.auth import identity_pool
from google.auth.exceptions import RefreshError
from google.auth.transport.requests import AuthorizedSession, Request


class CheckFailed(Exception):
    """Represent a fixed, non-secret failure explanation."""


class Audit:
    """Count successful exchanges and identify a specific IAM permission denial."""

    def __init__(self):
        self.request = Request()
        self.sts = 0
        self.iam = 0
        self.iam_denied = False

    def __call__(self, *args, **kwargs):
        kwargs["timeout"] = 20
        response = self.request(*args, **kwargs)
        url = kwargs.get("url", args[0] if args else "")
        if url.startswith("https://sts.googleapis.com/") and response.status == 200:
            self.sts += 1
        if url.startswith("https://iamcredentials.googleapis.com/"):
            if response.status == 200:
                self.iam += 1
            if response.status == 403:
                error = json.loads(response.data).get("error", {})
                self.iam_denied = error.get("status") == "PERMISSION_DENIED" and "iam.serviceAccounts.getAccessToken" in error.get("message", "")
        return response


def report(check, **fields):
    """Print only controlled status and numeric evidence."""
    print(json.dumps({"check": check, **fields}), flush=True)


def credentials():
    """Use only the mounted, explicit external-account configuration."""
    config = json.loads(Path("/var/run/wif-config/credentials.json").read_text())
    return identity_pool.Credentials.from_info(config, scopes=["https://www.googleapis.com/auth/cloud-platform"])


def allowed_read(session, bucket):
    """Require the exact harmless marker content from the allowed object."""
    url = "https://storage.googleapis.com/storage/v1/b/" + bucket + "/o/" + quote("smoke/allowed.txt", safe="") + "?alt=media"
    response = session.get(url, timeout=20)
    if response.status_code != 200 or response.content != b"build13 direct WIF allowed test object\n":
        raise CheckFailed("allowed object read failed or returned unexpected content")


def require_storage_denied(session, url, permission):
    """Require an explicit 403 for the expected storage permission."""
    response = session.get(url, timeout=20)
    if response.status_code != 403:
        raise CheckFailed("expected storage permission denial was not returned")
    # GCS returns HTML errors for alt=media and JSON errors for metadata/listing.
    if permission not in response.text:
        raise CheckFailed("storage rejection did not identify the expected permission")


def run(mode, bucket):
    """Exercise denied identity, limited object access, or automatic refresh."""
    audit = Audit()
    creds = credentials()
    if mode == "denied":
        try:
            creds.refresh(audit)
        except RefreshError:
            if audit.iam_denied:
                report("unauthorized-service-account", result="PASS", http_status=403, permission="iam.serviceAccounts.getAccessToken")
                return
            raise CheckFailed("authentication failed without the expected IAM denial")
        raise CheckFailed("unauthorized service account obtained credentials")

    with AuthorizedSession(creds, auth_request=audit) as session:
        allowed_read(session, bucket)
        if mode == "resource":
            base = "https://storage.googleapis.com/storage/v1/b/" + bucket + "/o"
            require_storage_denied(session, base + "/" + quote("smoke/denied.txt", safe="") + "?alt=media", "storage.objects.get")
            require_storage_denied(session, base + "?maxResults=1", "storage.objects.list")
            report("restricted-object-access", result="PASS", allowed_reads=1, forbidden_object_reads=1, forbidden_list_requests=1)
            return

        if mode != "renewal":
            raise CheckFailed("unknown test mode")
        start = time.monotonic()
        first_expiry = creds.expiry.replace(tzinfo=timezone.utc)
        target_tokens = set()
        projected_tokens = set()
        reads = 1
        while True:
            target_tokens.add(hashlib.sha256(creds.token.encode()).digest())
            projected_tokens.add(hashlib.sha256(Path("/var/run/wif/token").read_bytes()).digest())
            elapsed = int(time.monotonic() - start)
            report("renewal-progress", elapsed_seconds=elapsed, successful_reads=reads, target_token_generations=len(target_tokens), projected_token_generations=len(projected_tokens), successful_iam_refreshes=audit.iam, successful_sts_exchanges=audit.sts)
            if elapsed >= 900:
                break
            time.sleep(min(30, 900 - elapsed))
            allowed_read(session, bucket)
            reads += 1

        if datetime.now(timezone.utc) <= first_expiry or len(target_tokens) < 2 or audit.iam < 2:
            raise CheckFailed("automatic target credential refresh was not demonstrated past initial expiry")
        if len(projected_tokens) < 2:
            raise CheckFailed("projected Kubernetes token rotation was not observed")

        # A fresh credential object cannot reuse the first client's cached STS token.
        fresh_audit = Audit()
        with AuthorizedSession(credentials(), auth_request=fresh_audit) as fresh:
            allowed_read(fresh, bucket)
        if fresh_audit.sts < 1 or fresh_audit.iam < 1:
            raise CheckFailed("rotated projected token did not complete a fresh exchange")
        report("credential-renewal", result="PASS", elapsed_seconds=elapsed, target_token_generations=len(target_tokens), projected_token_generations=len(projected_tokens), automatic_iam_refreshes=audit.iam, fresh_sts_exchanges=fresh_audit.sts)


if __name__ == "__main__":
    try:
        run(sys.argv[1], sys.argv[2])
    except Exception as error:
        report("test", result="FAIL", reason=str(error) if isinstance(error, CheckFailed) else type(error).__name__)
        sys.exit(1)
