#!/bin/bash
set -euo pipefail

helper=$(mktemp)
trap 'rm -f "${helper}"' EXIT
cat > "${helper}" <<'PYTHON'
import hashlib
import http.client
import json
import os
from pathlib import Path
import re
import shutil
import subprocess
import tempfile
import time
import urllib.error
import urllib.request

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


def fetch_source(url):
    """Fetch bounded source bytes, retrying transport and transient HTTP errors only."""
    def fetch():
        try:
            with urllib.request.urlopen(url, timeout=30) as response:
                return response.read(1024 * 1024 + 1)
        except urllib.error.HTTPError as error:
            if error.code not in {408, 429} and not 500 <= error.code < 600:
                raise ValueError("Pinned source request failed with HTTP status " + str(error.code)) from error
            raise

    return retry_external(fetch, (urllib.error.URLError, TimeoutError, ConnectionError,
                                  http.client.HTTPException))


def gate_names(entries):
    names = {entry["name"] for entry in entries or []}
    if any(not isinstance(name, str) or not re.fullmatch(r"[A-Za-z][A-Za-z0-9]*", name)
           or name in {"AllAlpha", "AllBeta"} for name in names):
        raise ValueError("Invalid OpenShift feature gate name")
    return names


def catalog_gates(directory, version):
    major = version.split(".")[0]
    known = set()
    defaults = []
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
            defaults.append((enabled, disabled))
    if not known and not defaults:
        return None
    if len(defaults) != 1 or not known:
        raise ValueError("Expected one nonempty Default catalog for the installed payload/profile")
    return known, known - defaults[0][0]


def legacy_gates(source):
    source = re.sub(r"//[^\n]*|/\*.*?\*/", "", source, flags=re.S)
    blocks = []
    for declaration in (r"var FeatureSets = map\[FeatureSet\]\*FeatureGateEnabledDisabled",
                        r"var defaultFeatures = &FeatureGateEnabledDisabled"):
        match = re.search(declaration + r"\s*\{(.*?)\n\}", source, re.S)
        if not match:
            raise ValueError("Unsupported legacy payload API catalog declaration")
        blocks.append(match.group(1))
    allowed = {"defaultFeatures", "Enabled", "Disabled", "string", "newDefaultFeatures",
               "with", "without", "toFeatures"}
    names = set()
    for block in blocks:
        allowed.update(re.findall(r"\b([A-Za-z]\w*)\s*:", block))
        literals = re.findall(r'"([^"\n]*)"', block)
        if any(not re.fullmatch(r"[A-Za-z][A-Za-z0-9]*", name) for name in literals):
            raise ValueError("Unsupported legacy gate literal")
        names.update(literals)
        remaining = re.sub(r'"[^"\n]*"', "", block)
        if set(re.findall(r"\b[A-Za-z_]\w*\b", remaining)) - allowed:
            raise ValueError("Legacy catalog contains unevaluated gate expressions")
    if not names or names & {"AllAlpha", "AllBeta"}:
        raise ValueError("Empty or invalid legacy gate catalog")
    return names, names


def pinned_source(directory, component, path):
    """Validate an immutable payload source identity before fetching and hashing bytes."""
    references = json.loads((directory / "image-references").read_text())
    operator = next(tag for tag in references["spec"]["tags"] if tag["name"] == component)
    annotations = operator["annotations"]
    commit = annotations["io.openshift.build.commit.id"]
    repository = annotations["io.openshift.build.source-location"].removesuffix(".git")
    if repository != "https://github.com/openshift/" + component or not re.fullmatch(r"[a-f0-9]{40}", commit):
        raise ValueError("Payload does not identify a pinned operator source: " + component)
    url = "https://raw.githubusercontent.com/openshift/" + component + "/" + commit + "/" + path
    content = fetch_source(url)
    if len(content) > 1024 * 1024:
        raise ValueError("Pinned operator source exceeds expected size")
    return content.decode(), url + " sha256:" + hashlib.sha256(content).hexdigest()


def inherits_default(source):
    dispatches = re.findall(
        r"if featureGates\.Spec\.FeatureSet == configv1\.CustomNoUpgrade \{(.*?)\n\t\}",
        source, re.S)
    if len(dispatches) != 1:
        raise ValueError("Unsupported CustomNoUpgrade consumer dispatch")
    dispatch = re.sub(r"\s+", "", dispatches[0])
    modern = "completeFeatureGatesForCustom(knownFeatureSets[configv1.Default],"
    legacy = ("completeFeatureGates(knownFeatureSets,"
              "featureGates.Spec.FeatureGateSelection.CustomNoUpgrade.Enabled,"
              "featureGates.Spec.FeatureGateSelection.CustomNoUpgrade.Disabled)")
    if (modern in dispatch) == (legacy in dispatch):
        raise ValueError("Unknown or ambiguous CustomNoUpgrade baseline semantics")
    return modern in dispatch


def payload_gates(directory, version):
    result = catalog_gates(directory, version)
    if result is not None:
        consumer, source = pinned_source(directory, "cluster-config-operator",
                                         "pkg/operator/featuregates/featuregate_controller.go")
        inherited = inherits_default(consumer)
        known, overrides = result
        return (known, overrides if inherited else known), (
            "payload FeatureGate catalogs; Default inheritance=" + str(inherited) + "; " + source)
    if tuple(map(int, version.split(".")[:2])) >= (4, 14):
        raise ValueError("Installed payload has no FeatureGate catalogs")
    content, source = pinned_source(directory, "cluster-kube-apiserver-operator",
                                    "vendor/github.com/openshift/api/config/v1/types_feature.go")
    return legacy_gates(content), source


def configure_install_config(path, selection):
    config = yaml.safe_load(path.read_text())
    config["featureSet"] = "CustomNoUpgrade"
    if tuple(map(int, selection["version"].split(".")[:2])) >= (4, 14):
        config["featureGates"] = [name + "=true" for name in selection["overrides"]]
    else:
        config.pop("featureGates", None)
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
            return payload_gates(Path(temporary), version)

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
    (known, forced), source = extract_payload_gates(installed_image, version)
    selection = {"target": target_version, "version": version, "source": source,
                 "known": sorted(known), "overrides": sorted(forced)}
    manifest = {"apiVersion": "config.openshift.io/v1", "kind": "FeatureGate",
                "metadata": {"name": "cluster"},
                "spec": {"featureSet": "CustomNoUpgrade", "customNoUpgrade": {
                    "enabled": selection["overrides"], "disabled": []}}}
    prepared = shared / "okd-ci-featuregates"
    prepared.mkdir()
    (prepared / "selection.json").write_text(json.dumps(selection, indent=2) + "\n")
    (prepared / "cluster-feature-gate.yaml").write_text(yaml.safe_dump(manifest, sort_keys=False))
    configure_install_config(shared / "install-config.yaml", selection)
    shutil.copyfile(prepared / "cluster-feature-gate.yaml", shared / "openshift_manifests_99_feature-gate.yaml")
    print("OKD CI target " + target_version + ": overriding prior gate selection with CustomNoUpgrade; "
          + str(len(known)) + " known gates enabled for installed payload " + version
          + " (" + str(len(forced)) + " explicit overrides); catalog: " + source)


if __name__ == "__main__":
    prepare()
PYTHON
python3 "${helper}"
