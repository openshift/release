#!/usr/bin/env python3
"""Render additive, separately named build13 authorization and renewal Jobs."""

import copy
import json
import re
import shlex
import sys
from pathlib import Path

from manifest import NAMESPACE, manifest


def render(config, suffix, bucket):
    """Preserve existing resources and run all checks with the pinned CLI image."""
    if not re.fullmatch(r"[a-f0-9]{6}", suffix):
        raise ValueError("run suffix must be six hex characters")
    if not re.fullmatch(r"openshift-ci-build13-wif-smoke-20261116-[a-f0-9]{6}", bucket):
        raise ValueError("use only a dedicated build13 smoke-test bucket")
    base = manifest(config)["items"][2]
    config_name = "gcp-wif-checks-" + suffix
    denied_sa = "gcp-smoke-denied-" + suffix
    items = [
        {"apiVersion": "v1", "kind": "ServiceAccount", "metadata": {"name": denied_sa, "namespace": NAMESPACE}, "automountServiceAccountToken": False},
        {"apiVersion": "v1", "kind": "ConfigMap", "metadata": {"name": config_name, "namespace": NAMESPACE}, "data": {"credentials.json": json.dumps(config), "checks.py": Path(__file__).with_name("checks.py").read_text()}},
    ]
    for mode in ("renewal", "resource", "denied"):
        job = copy.deepcopy(base)
        job["metadata"]["name"] = "gcp-wif-" + mode + "-" + suffix
        job["spec"]["activeDeadlineSeconds"] = 1200 if mode == "renewal" else 300
        pod = job["spec"]["template"]["spec"]
        if mode == "denied":
            pod["serviceAccountName"] = denied_sa
        next(v for v in pod["volumes"] if v["name"] == "config")["configMap"]["name"] = config_name
        pod["containers"][0]["command"] = ["/bin/sh", "-c", "\n".join([
            "set -eu",
            'export GOOGLE_SDK_ROOT="$(gcloud info --format=\'value(installation.sdk_root)\')"',
            'SDK_PYTHON="$(gcloud info --format=\'value(basic.python_location)\')"',
            'exec "$SDK_PYTHON" /var/run/wif-config/checks.py ' + shlex.quote(mode) + " " + shlex.quote(bucket),
        ])]
        items.append(job)
    return {"apiVersion": "v1", "kind": "List", "items": items}


if __name__ == "__main__":
    print(json.dumps(render(json.loads(Path(sys.argv[1]).read_text()), sys.argv[2], sys.argv[3]), indent=2))
