"""Render an isolated standard-client test with no shared profile or static key."""

import argparse
import json
from pathlib import Path


PYTHON_IMAGE = "registry.access.redhat.com/ubi9/python-312@sha256:19e1e927138b40454858f297884c2c4e2f13f5ba95b3f55faea174d3cbb57067"
GCLOUD_IMAGE = "gcr.io/google.com/cloudsdktool/google-cloud-cli@sha256:54e711173abf8aebf025d0a20815088bfb6ab627eae39d8d0ab6df6ec114cbf6"


def manifest(namespace, name):
    source = Path(__file__).parent
    aws_config = """[profile home]
role_arn = arn:aws:iam::891612575819:role/ci-step-runner
web_identity_token_file = /var/run/aws-token/token
region = us-east-1

[profile ci-hub]
role_arn = arn:aws:iam::320297955214:role/ci-step-runner-hub
source_profile = home
region = us-east-1
"""
    credentials = {
        "type": "external_account",
        "audience": "//iam.googleapis.com/projects/263120870185/locations/global/workloadIdentityPools/ci-aws-pilot/providers/aws-ci-hub",
        "subject_token_type": "urn:ietf:params:aws:token-type:aws4_request",
        "token_url": "https://sts.googleapis.com/v1/token",
        "service_account_impersonation_url": "https://iamcredentials.googleapis.com/v1/projects/-/serviceAccounts/ci-provisioner-2@openshift-gce-devel-ci-2.iam.gserviceaccount.com:generateAccessToken",
        "service_account_impersonation": {"token_lifetime_seconds": 600},
        "credential_source": {
            "environment_id": "aws1", "region_url": "http://127.0.0.1:8085/region",
            "url": "http://127.0.0.1:8085/security-credentials",
            "regional_cred_verification_url": "https://sts.{region}.amazonaws.com?Action=GetCallerIdentity&Version=2011-06-15",
        },
    }
    config = {"apiVersion": "v1", "kind": "ConfigMap", "metadata": {"name": name, "namespace": namespace}, "data": {
        "aws-config": aws_config, "gcp-creds.json": json.dumps(credentials),
        "bridge.py": (source / "gcloud_bridge.py").read_text(),
        "check.py": (source / "gcloud_check.py").read_text(),
        "requirements.txt": (source / "requirements.txt").read_text(),
    }}
    limits = {"requests": {"cpu": "100m", "memory": "256Mi"}, "limits": {"memory": "768Mi"}}
    bridge = {
        "name": "aws-bridge", "image": PYTHON_IMAGE, "restartPolicy": "Always",
        "command": ["/bin/bash", "-c"], "args": ["set -euo pipefail\npython3 -m venv /tmp/aws-venv\n/tmp/aws-venv/bin/python -m pip install --quiet --disable-pip-version-check --no-cache-dir -r /config/requirements.txt\nexec /tmp/aws-venv/bin/python /config/bridge.py\n"],
        "env": [{"name": "PYTHONDONTWRITEBYTECODE", "value": "1"}],
        "resources": limits,
        "volumeMounts": [{"name": "config", "mountPath": "/config", "readOnly": True}, {"name": "aws-token", "mountPath": "/var/run/aws-token", "readOnly": True}],
        "startupProbe": {"exec": {"command": ["python3", "-c", "import urllib.request; urllib.request.urlopen('http://127.0.0.1:8085/healthz', timeout=2).read()"]}, "periodSeconds": 5, "failureThreshold": 60},
    }
    client = {
        "name": "gcloud-check", "image": GCLOUD_IMAGE,
        "command": ["/bin/bash", "-c"],
        "args": ["set -euo pipefail\npython=$(gcloud info --format='value(basic.python_location)')\nexec \"$python\" /config/check.py\n"],
        "env": [{"name": "HOME", "value": "/tmp"}, {"name": "CLOUDSDK_CONFIG", "value": "/tmp/gcloud"}, {"name": "GOOGLE_APPLICATION_CREDENTIALS", "value": "/config/gcp-creds.json"}, {"name": "PYTHONDONTWRITEBYTECODE", "value": "1"}],
        "resources": limits,
        "volumeMounts": [{"name": "config", "mountPath": "/config", "readOnly": True}, {"name": "tmp", "mountPath": "/tmp"}],
        "securityContext": {"allowPrivilegeEscalation": False, "readOnlyRootFilesystem": True, "capabilities": {"drop": ["ALL"]}},
    }
    job = {"apiVersion": "batch/v1", "kind": "Job", "metadata": {"name": name, "namespace": namespace}, "spec": {
        "backoffLimit": 0, "activeDeadlineSeconds": 900,
        "template": {"spec": {"automountServiceAccountToken": False, "restartPolicy": "Never", "initContainers": [bridge], "containers": [client], "volumes": [
            {"name": "config", "configMap": {"name": name}}, {"name": "tmp", "emptyDir": {"medium": "Memory"}},
            {"name": "aws-token", "projected": {"sources": [{"serviceAccountToken": {"audience": "sts.amazonaws.com", "expirationSeconds": 600, "path": "token"}}]}},
        ]}},
    }}
    return {"apiVersion": "v1", "kind": "List", "items": [config, job]}


if __name__ == "__main__":
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--namespace", required=True)
    parser.add_argument("--name", required=True)
    args = parser.parse_args()
    print(json.dumps(manifest(args.namespace, args.name), indent=2))
