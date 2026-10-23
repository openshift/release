#!/bin/bash
set -euo pipefail

helper=$(mktemp)
trap 'rm -f "${helper}"' EXIT
cat > "${helper}" <<'PYTHON'
import hashlib
import json
import os
from pathlib import Path
import re
import shutil
import subprocess
import sys
import tempfile
import urllib.request

import yaml


PROFILE = "include.release.openshift.io/self-managed-high-availability"
OVERRIDES = "agent-install.openshift.io/install-config-overrides"
CI_VERSION = re.compile(r"\d+\.\d+\.0-0\.okd(?:-scos)?(?:-arm64)?-\d{4}-\d{2}-\d{2}-\d{6}")


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
    references = json.loads((directory / "image-references").read_text())
    operator = next(tag for tag in references["spec"]["tags"] if tag["name"] == component)
    annotations = operator["annotations"]
    commit = annotations["io.openshift.build.commit.id"]
    repository = annotations["io.openshift.build.source-location"].removesuffix(".git")
    if repository != "https://github.com/openshift/" + component or not re.fullmatch(r"[a-f0-9]{40}", commit):
        raise ValueError("Payload does not identify a pinned operator source: " + component)
    url = "https://raw.githubusercontent.com/openshift/" + component + "/" + commit + "/" + path
    with urllib.request.urlopen(url, timeout=30) as response:
        content = response.read(1024 * 1024 + 1)
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


def configure_agent(directory, prepared):
    selection = json.loads((prepared / "selection.json").read_text())
    install_config = directory / "install-config.yaml"
    agent_install = directory / "cluster-manifests/agent-cluster-install.yaml"
    if install_config.exists():
        configure_install_config(install_config, selection)
    elif agent_install.exists():
        obj = yaml.safe_load(agent_install.read_text())
        annotations = obj.setdefault("metadata", {}).setdefault("annotations", {})
        overrides = json.loads(annotations.get(OVERRIDES, "{}"))
        overrides.update(featureSet="CustomNoUpgrade",
                         featureGates=[name + "=true" for name in selection["overrides"]])
        annotations[OVERRIDES] = json.dumps(overrides, separators=(",", ":"))
        agent_install.write_text(yaml.safe_dump(obj, sort_keys=False))
    else:
        raise ValueError("Agent configuration must exist before preparing feature gates")
    extra = directory / "openshift"
    extra.mkdir(exist_ok=True)
    shutil.copyfile(prepared / "cluster-feature-gate.yaml", extra / "99_feature-gate.yaml")


def release_info(image):
    return json.loads(subprocess.check_output([
        "oc", "adm", "release", "info", "-a", os.environ["CLUSTER_PROFILE_DIR"] + "/pull-secret",
        image, "--output=json"], text=True))


def prepare():
    target = release_info(os.environ["RELEASE_IMAGE_LATEST"])
    target_version = target["metadata"]["version"]
    if not CI_VERSION.fullmatch(target_version):
        print("Preserving feature gates for non-OKD-CI target " + target_version)
        return
    shared = Path(os.environ["SHARED_DIR"])
    installer = os.environ.get("OKD_CI_FEATURE_GATES_INSTALLER", "ipi")
    installed_image = os.environ["OPENSHIFT_INSTALL_RELEASE_IMAGE_OVERRIDE"]
    if installer == "agent" and os.environ.get("ARCHITECTURE") != "arm64":
        installed_image = os.environ["OPENSHIFT_INSTALL_RELEASE_IMAGE"]
    if installer == "ipi":
        installed_image = os.environ.get("CUSTOM_OPENSHIFT_INSTALL_RELEASE_IMAGE_OVERRIDE") or installed_image
    installed = release_info(installed_image)
    version = installed["metadata"]["version"]
    with tempfile.TemporaryDirectory() as temporary:
        directory = Path(temporary)
        subprocess.run(["oc", "adm", "release", "extract", "-a",
                        os.environ["CLUSTER_PROFILE_DIR"] + "/pull-secret", installed_image,
                        "--to=" + temporary], check=True)
        (known, forced), source = payload_gates(directory, version)
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
    if installer == "ipi":
        configure_install_config(shared / "install-config.yaml", selection)
        shutil.copyfile(prepared / "cluster-feature-gate.yaml", shared / "openshift_manifests_99_feature-gate.yaml")
    else:
        shutil.copyfile(__file__, prepared / "helper.py")
        (prepared / "agent.mk").write_text(
            ".PHONY: okd-ci-featuregates\n"
            "agent_create_cluster: okd-ci-featuregates\n"
            "okd-ci-featuregates: agent_configure\n"
            "\tbash -c 'source ./common.sh; python3 /root/okd-ci-featuregates/helper.py "
            "agent \"$${OCP_DIR}\" /root/okd-ci-featuregates'\n")
    print("OKD CI target " + target_version + ": overriding prior gate selection with CustomNoUpgrade; "
          + str(len(known)) + " known gates enabled for installed payload " + version
          + " (" + str(len(forced)) + " explicit overrides); catalog: " + source)


if __name__ == "__main__":
    if len(sys.argv) == 4 and sys.argv[1] == "agent":
        configure_agent(Path(sys.argv[2]), Path(sys.argv[3]))
    else:
        prepare()
PYTHON
python3 "${helper}"
