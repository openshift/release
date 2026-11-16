#!/usr/bin/env python3
"""Render an isolated build13 Job from gcloud's public external-account config."""

import json
import sys

IMAGE = "gcr.io/google.com/cloudsdktool/google-cloud-cli@sha256:54e711173abf8aebf025d0a20815088bfb6ab627eae39d8d0ab6df6ec114cbf6"
NAMESPACE = "gcp-wif-smoke-nirichar"
SERVICE_ACCOUNT = "gcp-smoke"


def manifest(config):
    """Build a Job with only a projected OIDC token and external-account config."""
    provider = "projects/263120870185/locations/global/workloadIdentityPools/build13/providers/build13"
    assert config["type"] == "external_account", "not an external-account configuration"
    assert config["audience"] == "//iam.googleapis.com/" + provider, "unexpected provider"
    assert config["subject_token_type"] == "urn:ietf:params:oauth:token-type:jwt", "not an OIDC token"
    assert config["token_url"] == "https://sts.googleapis.com/v1/token", "unexpected STS endpoint"
    assert config["credential_source"] == {"file": "/var/run/wif/token", "format": {"type": "text"}}, "unexpected token source"
    assert config["service_account_impersonation_url"] == "https://iamcredentials.googleapis.com/v1/projects/-/serviceAccounts/build13-wif-smoke@openshift-ci-build-farm.iam.gserviceaccount.com:generateAccessToken", "unexpected service account"
    command = """set -eu
gcloud auth login --cred-file=/var/run/wif-config/credentials.json --quiet
gcloud auth print-access-token > /dev/null
printf 'PASS: build13 pod identity obtained short-lived GCP credentials.\\n'
"""
    return {"apiVersion": "v1", "kind": "List", "items": [
        {"apiVersion": "v1", "kind": "ServiceAccount", "metadata": {"name": SERVICE_ACCOUNT, "namespace": NAMESPACE}, "automountServiceAccountToken": False},
        {"apiVersion": "v1", "kind": "ConfigMap", "metadata": {"name": "gcp-wif-config", "namespace": NAMESPACE}, "data": {"credentials.json": json.dumps(config)}},
        {"apiVersion": "batch/v1", "kind": "Job", "metadata": {"name": "gcp-wif-smoke", "namespace": NAMESPACE}, "spec": {
            "backoffLimit": 0, "activeDeadlineSeconds": 300,
            "template": {"metadata": {"labels": {"app": "gcp-wif-smoke"}}, "spec": {
                "serviceAccountName": SERVICE_ACCOUNT, "automountServiceAccountToken": False, "restartPolicy": "Never",
                "securityContext": {"runAsNonRoot": True, "seccompProfile": {"type": "RuntimeDefault"}},
                "containers": [{"name": "smoke", "image": IMAGE, "command": ["/bin/sh", "-c", command],
                    "env": [{"name": "HOME", "value": "/tmp"}, {"name": "CLOUDSDK_CONFIG", "value": "/tmp/gcloud"}, {"name": "GOOGLE_APPLICATION_CREDENTIALS", "value": "/var/run/wif-config/credentials.json"}, {"name": "PYTHONDONTWRITEBYTECODE", "value": "1"}],
                    "securityContext": {"allowPrivilegeEscalation": False, "readOnlyRootFilesystem": True, "capabilities": {"drop": ["ALL"]}},
                    "resources": {"requests": {"cpu": "100m", "memory": "128Mi"}, "limits": {"memory": "512Mi"}},
                    "volumeMounts": [{"name": "oidc", "mountPath": "/var/run/wif", "readOnly": True}, {"name": "config", "mountPath": "/var/run/wif-config", "readOnly": True}, {"name": "tmp", "mountPath": "/tmp"}]}],
                "volumes": [{"name": "oidc", "projected": {"sources": [{"serviceAccountToken": {"audience": "openshift", "expirationSeconds": 600, "path": "token"}}]}}, {"name": "config", "configMap": {"name": "gcp-wif-config"}}, {"name": "tmp", "emptyDir": {}}]
            }}
        }}
    ]}


if __name__ == "__main__":
    with open(sys.argv[1]) as source:
        print(json.dumps(manifest(json.load(source)), indent=2))
