#!/bin/bash
set -euo pipefail

helper=$(mktemp)
trap 'rm -f "${helper}"' EXIT
cat > "${helper}" <<'PYTHON'
import json
import os
from pathlib import Path
import re
import shutil
import subprocess
import tempfile
import time

import yaml


PROFILE = "include.release.openshift.io/self-managed-high-availability"
CI_VERSION = re.compile(r"\d+\.\d+\.0-0\.okd(?:-scos)?(?:-arm64)?-\d{4}-\d{2}-\d{2}-\d{6}")


def retry_external(operation, retryable):
    """Make at most three transport attempts with backoff; let semantic errors fail."""
    for attempt in range(3):
        try:
            return operation()
        except retryable:
            if attempt == 2:
                raise
            time.sleep(2 ** attempt)


def gate_names(entries):
    names = {entry["name"] for entry in entries or []}
    if any(not isinstance(name, str) or not re.fullmatch(r"[A-Za-z][A-Za-z0-9]*", name)
           or name in {"AllAlpha", "AllBeta"} for name in names):
        raise ValueError("Invalid OpenShift feature gate name")
    return names


def catalog_gates(directory, version):
    """Union every applicable payload catalog, independently of Default inheritance."""
    major = version.split(".")[0]
    known = set()
    defaults = 0
    for path in sorted(directory.glob("*featureGate-*.yaml")):
        obj = yaml.safe_load(path.read_text())
        if obj.get("apiVersion") != "config.openshift.io/v1" or obj.get("kind") != "FeatureGate":
            continue
        annotations = obj.get("metadata", {}).get("annotations") or {}
        profiles = {key for key in annotations if key.startswith("include.release.openshift.io/")}
        if profiles and PROFILE not in profiles:
            continue
        majors = annotations.get("release.openshift.io/major-version")
        if majors is not None and major not in majors.split(","):
            continue
        statuses = [status for status in obj.get("status", {}).get("featureGates", []) or []
                    if status.get("version", "") in {"", version}]
        if len(statuses) != 1:
            raise ValueError("Ambiguous or missing installed-version FeatureGate status: " + path.name)
        enabled = gate_names(statuses[0].get("enabled"))
        disabled = gate_names(statuses[0].get("disabled"))
        if enabled & disabled:
            raise ValueError("Catalog enables and disables the same feature")
        known.update(enabled | disabled)
        feature_set = obj.get("spec", {}).get("featureSet") or "Default"
        if feature_set == "Default":
            if not enabled and not disabled:
                raise ValueError("Empty Default FeatureGate catalog: " + path.name)
            defaults += 1
    if defaults != 1 or not known:
        raise ValueError("Missing or incompatible FeatureGate catalogs for installed payload "
                         + version + " / " + PROFILE + "; expected one nonempty Default catalog")
    return known


def configure_install_config(path, selection):
    config = yaml.safe_load(path.read_text())
    config["featureSet"] = "CustomNoUpgrade"
    config["featureGates"] = [name + "=true" for name in selection["enabled"]]
    path.write_text(yaml.safe_dump(config, sort_keys=False))


def release_info(image):
    """Bound release-info attempts, then parse the metadata once without retrying it."""
    output = retry_external(lambda: subprocess.check_output([
        "oc", "adm", "release", "info", "-a", os.environ["CLUSTER_PROFILE_DIR"] + "/pull-secret",
        image, "--output=json"], text=True, timeout=120),
        (subprocess.CalledProcessError, subprocess.TimeoutExpired))
    return json.loads(output)


def extract_payload_gates(image, version):
    """Isolate every extraction attempt; retry commands, never catalog validation."""
    def extract():
        with tempfile.TemporaryDirectory() as temporary:
            subprocess.run(["oc", "adm", "release", "extract", "-a",
                            os.environ["CLUSTER_PROFILE_DIR"] + "/pull-secret", image,
                            "--to=" + temporary], check=True, timeout=600)
            return catalog_gates(Path(temporary), version)

    return retry_external(extract, (subprocess.CalledProcessError, subprocess.TimeoutExpired))


def prepare():
    target = release_info(os.environ["RELEASE_IMAGE_LATEST"])
    target_version = target["metadata"]["version"]
    if not CI_VERSION.fullmatch(target_version):
        print("Preserving feature gates for non-OKD-CI target " + target_version)
        return
    shared = Path(os.environ["SHARED_DIR"])
    installed_image = os.environ["OPENSHIFT_INSTALL_RELEASE_IMAGE_OVERRIDE"]
    installed_image = os.environ.get("CUSTOM_OPENSHIFT_INSTALL_RELEASE_IMAGE_OVERRIDE") or installed_image
    installed = release_info(installed_image)
    version = installed["metadata"]["version"]
    known = extract_payload_gates(installed_image, version)
    selection = {"target": target_version, "version": version, "enabled": sorted(known)}
    manifest = {"apiVersion": "config.openshift.io/v1", "kind": "FeatureGate",
                "metadata": {"name": "cluster"},
                "spec": {"featureSet": "CustomNoUpgrade", "customNoUpgrade": {
                    "enabled": selection["enabled"], "disabled": []}}}
    prepared = shared / "okd-ci-featuregates"
    prepared.mkdir()
    (prepared / "selection.json").write_text(json.dumps(selection, indent=2) + "\n")
    (prepared / "cluster-feature-gate.yaml").write_text(yaml.safe_dump(manifest, sort_keys=False))
    configure_install_config(shared / "install-config.yaml", selection)
    shutil.copyfile(prepared / "cluster-feature-gate.yaml", shared / "openshift_manifests_99_feature-gate.yaml")
    print("OKD CI target " + target_version + ": overriding prior gate selection with CustomNoUpgrade; "
          + str(len(known)) + " known gates enabled for installed payload " + version
          + " from payload FeatureGate catalogs")


if __name__ == "__main__":
    prepare()
PYTHON
python3 "${helper}"
