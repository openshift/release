"""Check standard gcloud and Google ADC clients with AWS hub federation."""

import json
import os
import subprocess
import sys


def gcloud(*arguments):
    result = subprocess.run(["gcloud", *arguments], capture_output=True, text=True)
    if result.returncode:
        # CLI errors can contain auth details. Emit only the check's fixed label.
        raise RuntimeError("gcloud command failed")
    return result.stdout


def main():
    sdk_root = gcloud("info", "--format=value(installation.sdk_root)").strip()
    sys.path.insert(0, os.path.join(sdk_root, "lib", "third_party"))
    from google.auth import load_credentials_from_file
    from google.auth.transport.requests import AuthorizedSession

    path = "/config/gcp-creds.json"
    project = "openshift-gce-devel-ci-2"
    config = json.load(open(path))
    if config.get("type") != "external_account" or "private_key" in config:
        raise ValueError("only external-account credentials are allowed")
    print(json.dumps({"check": "external-account-config", "result": "passed"}), flush=True)
    gcloud("auth", "login", "--cred-file=" + path, "--quiet")
    gcloud("auth", "print-access-token")
    print(json.dumps({"check": "gcloud-impersonation", "result": "passed"}), flush=True)
    zones = json.loads(gcloud("compute", "zones", "list", "--project=" + project, "--limit=1", "--format=json"))
    if not zones:
        raise ValueError("gcloud did not return a zone")
    print(json.dumps({"check": "gcloud-compute-zones-read", "result": "passed"}), flush=True)
    credentials, _ = load_credentials_from_file(path, scopes=["https://www.googleapis.com/auth/cloud-platform"])
    response = AuthorizedSession(credentials).get("https://compute.googleapis.com/compute/v1/projects/" + project + "/zones?maxResults=1", timeout=30)
    if response.status_code != 200 or not response.json().get("items"):
        raise ValueError("standard ADC compute read did not succeed")
    print(json.dumps({"check": "standard-google-adc-compute-read", "result": "passed"}), flush=True)


if __name__ == "__main__":
    try:
        main()
    except Exception as error:
        print(json.dumps({"result": "failed", "error_type": type(error).__name__}), flush=True)
        raise SystemExit(1)
