#!/usr/bin/env python3
"""Generate ordered CoreOS publication in the existing okd-scos images job."""

import argparse
import copy
import difflib
import hashlib
import json
from pathlib import Path

import yaml


CONFIG = "ci-operator/config/openshift/os/openshift-os-master__okd-scos.yaml"
STEP = "ci-operator/step-registry/openshift/os-publish-art/openshift-os-publish-art"
JOB = "branch-ci-openshift-os-master-okd-scos-images"
PUBLISHER = "branch-ci-openshift-os-master-okd-scos-publish-art"
VALIDATION_CONFIG = "ci-operator/config/openshift/release/openshift-release-main.yaml"
VALIDATION_WAIT = '''for ((attempt = 0; attempt < 60; attempt++)); do
  if [[ -f /validation-tools/ready ]]; then
    exec "$@"
  fi
  sleep 1
done
echo 'Generated-config tools did not become ready' >&2
exit 1
'''


class JobDumper(yaml.SafeDumper):
    """Use the literal multiline style used by the standard Prow serializer."""


def job_string(dumper, value):
    """Keep generated wrapper source readable and formatting deterministic."""
    style = None
    if "\n" in value:
        style = "|"
    elif not value or dumper.resolve(yaml.ScalarNode, value, (True, False)) != "tag:yaml.org,2002:str":
        style = '"'
    return dumper.represent_scalar("tag:yaml.org,2002:str", value, style=style)


JobDumper.add_representer(str, job_string)


def write_jobs(path, document):
    """Serialize jobs in the standard sorted Prow layout."""
    path.write_text(yaml.dump(document, Dumper=JobDumper, sort_keys=True, width=80))

WRAPPER = r'''import json
import os
from pathlib import Path
import re
import subprocess
import sys
import tempfile

def require(condition, message):
    if not condition:
        raise ValueError(message)

def read_json(path):
    require(path.is_file() and not path.is_symlink(), "Missing or unsafe handoff file")
    return json.loads(path.read_text())

def build_digests(artifacts, job):
    metadata = read_json(artifacts / "metadata.json")
    refs = job["refs"]
    require(metadata.get("pod") == job["prowjobid"] and
            metadata.get("repo") == "openshift/os" and
            metadata.get("repos") == {"openshift/os": refs["base_ref"] + ":" + refs["base_sha"]},
            "Handoff does not belong to this job and commit")
    namespace = metadata.get("work-namespace", "")
    require(re.fullmatch(r"ci-op-[a-z0-9-]+", namespace), "Invalid handoff namespace")
    snapshot = read_json(artifacts / "build-resources/imagestreams.json")
    require(snapshot.get("kind") == "ImageStreamList" and
            snapshot.get("apiVersion") == "image.openshift.io/v1", "Invalid stream snapshot")
    streams = [stream for stream in snapshot["items"] if stream["metadata"]["name"] == "pipeline"]
    require(len(streams) == 1, "Expected exactly one originating pipeline stream")
    stream = streams[0]
    require(stream["metadata"]["namespace"] == namespace and stream["metadata"].get("uid"),
            "Foreign pipeline stream")
    digests = []
    for tag in ("stream-coreos", "stream-coreos-extensions"):
        statuses = [entry for entry in stream["status"]["tags"] if entry["tag"] == tag]
        require(len(statuses) == 1 and statuses[0].get("items"), "Missing or duplicate build output")
        latest = statuses[0]["items"][0]
        digest = latest.get("image", "")
        require(re.fullmatch(r"sha256:[a-f0-9]{64}", digest), "Invalid build digest")
        require(latest.get("dockerImageReference", "").endswith("@" + digest),
                "Build digest and promotion source disagree")
        specs = [entry for entry in stream.get("spec", {}).get("tags", []) if entry["name"] == tag]
        require(len(specs) <= 1, "Duplicate build specification")
        if specs and specs[0].get("generation") is not None:
            require(specs[0]["generation"] == latest.get("generation"), "Pending build output")
        digests.append(digest)
    return digests

def main():
    payload = json.loads(sys.argv[1])
    job = json.loads(os.environ["JOB_SPEC"])
    refs = job.get("refs", {})
    require(job.get("type") == "postsubmit" and
            job.get("job") == "branch-ci-openshift-os-master-okd-scos-images" and
            job.get("prowjobid") and not job.get("extra_refs") and not refs.get("pulls") and
            refs.get("org") == "openshift" and refs.get("repo") == "os" and
            refs.get("base_ref") == "master" and
            re.fullmatch(r"[a-f0-9]{40}", refs.get("base_sha", "")), "Unexpected originating job")
    artifacts = Path(os.environ["ARTIFACTS"])
    for relative in ("metadata.json", "build-resources", "art-publication"):
        require(not (artifacts / relative).exists() and not (artifacts / relative).is_symlink(),
                "Refusing stale or reused handoff artifacts")
    with tempfile.TemporaryDirectory(prefix="scos-publication-") as temporary:
        config = Path(temporary) / "config.json"
        config.write_text(json.dumps(payload["config"]))
        result = subprocess.run(["ci-operator", "--config=" + str(config)] + payload["images"], check=False)
        if result.returncode:
            return result.returncode if result.returncode > 0 else 128 - result.returncode
        digests = build_digests(artifacts, job)
        frozen = {"prowjobid": job["prowjobid"], "base_sha": refs["base_sha"], "digests": digests}
        (Path(temporary) / "handoff.json").write_text(json.dumps(frozen))
        environment = dict(os.environ, ARTIFACTS=str(artifacts / "art-publication"))
        overrides = ["--dependency-override-param=" + name +
                     "=quay-proxy.ci.openshift.org/openshift/ci@" + digest
                     for name, digest in zip(("STREAM_COREOS_IMAGE", "STREAM_COREOS_EXTENSIONS_IMAGE"), digests)]
        result = subprocess.run(["ci-operator", "--config=" + str(config)] +
                                payload["publisher"] + ["--promote=false"] + overrides,
                                env=environment, check=False)
        return result.returncode if result.returncode >= 0 else 128 - result.returncode

try:
    sys.exit(main())
except (ValueError, KeyError, TypeError, OSError, IndexError):
    sys.exit("Ordered publication failed: invalid inputs or unavailable build handoff; no subsequent stage authorized")
'''


def pinned_config(root):
    """Resolve the one literal publisher without changing the normal image inputs."""
    config = yaml.safe_load((root / CONFIG).read_text())
    if config["promotion"] != {"to": [{"name": "scos-5.1", "namespace": "origin"}]}:
        raise ValueError("Unexpected normal promotion contract")
    if [image["to"] for image in config["images"]["items"]] != ["stream-coreos", "stream-coreos-extensions"]:
        raise ValueError("Unexpected CoreOS outputs")
    publisher = next(test for test in config["tests"] if test["as"] == "publish-art")
    if publisher["steps"] != {"test": [{"ref": "openshift-os-publish-art"}]}:
        raise ValueError("Unexpected publisher test")
    literal = yaml.safe_load((root / (STEP + "-ref.yaml")).read_text())["ref"]
    literal["commands"] = (root / (STEP + "-commands.sh")).read_text()
    publisher = {key: value for key, value in publisher.items() if key != "steps"}
    publisher["literal_steps"] = {"test": [literal]}
    config["tests"] = [publisher]
    return config


def merge_named(original, additional, key):
    """Keep existing entries, rejecting a conflicting credential or pod setting."""
    merged = copy.deepcopy(original)
    for entry in additional:
        matches = [current for current in merged if current[key] == entry[key]]
        if matches and matches != [entry]:
            raise ValueError("Conflicting generated pod setting")
        if not matches:
            merged.append(copy.deepcopy(entry))
    return merged


def generate(root, jobs_root, bootstrap=None, check_bootstrap=False):
    """Transform only the two explicitly named generated variant jobs."""
    path = jobs_root / "openshift/os/openshift-os-master-postsubmits.yaml"
    if not path.exists():
        return
    original = path.read_text()
    document = yaml.safe_load(original)
    jobs = document["postsubmits"]["openshift/os"]
    images = [job for job in jobs if job["name"] == JOB]
    publishers = [job for job in jobs if job["name"] == PUBLISHER]
    if len(images) != 1:
        raise ValueError("Expected exactly one CoreOS images job")
    images = images[0]
    container = images["spec"]["containers"][0]
    config = pinned_config(root)
    if container.get("command") == ["python3", "-c", WRAPPER]:
        if publishers or json.loads(container["args"][0])["config"] != config:
            raise ValueError("Regenerate with standard prowgen before the ordered phase")
        return
    if len(publishers) != 1:
        raise ValueError("Expected exactly one generated publisher")
    publisher = publishers[0]
    publishing_container = publisher["spec"]["containers"][0]
    for job, target in ((images, "[images]"), (publisher, "publish-art")):
        spec = job["spec"]
        current = spec["containers"]
        expected = {"branches": ["^master$"], "max_concurrency": 1}
        if any(job.get(key) != value for key, value in expected.items()):
            raise ValueError("Unexpected generated CoreOS job settings")
        allowed_clusters = ("build13",) if job is images else (None, "build13")
        if job.get("cluster") not in allowed_clusters:
            raise ValueError("Unexpected generated CoreOS cluster")
        if (job["labels"].get("ci.openshift.io/generator") != "prowgen" or
                job["labels"].get("ci-operator.openshift.io/variant") != "okd-scos" or
                spec["serviceAccountName"] != "ci-operator" or len(current) != 1):
            raise ValueError("Unexpected generated CoreOS pod identity")
        if (current[0]["command"] != ["ci-operator"] or
                "--target=" + target not in current[0]["args"] or
                "--variant=okd-scos" not in current[0]["args"]):
            raise ValueError("Unexpected generated CoreOS job shape")
    if "--promote" not in container["args"] or any(
            argument.startswith("--promote") for argument in publishing_container["args"]):
        raise ValueError("Unexpected promotion options")
    if container["image"] != publishing_container["image"]:
        raise ValueError("Mismatched ci-operator images")
    payload = {"config": config, "images": container["args"], "publisher": publishing_container["args"]}
    container["command"] = ["python3", "-c", WRAPPER]
    container["args"] = [json.dumps(payload, sort_keys=True, separators=(",", ":"))]
    for key, identity in (("volumeMounts", "mountPath"), ("env", "name"), ("ports", "containerPort")):
        container[key] = merge_named(container.get(key, []), publishing_container.get(key, []), identity)
    images["spec"]["volumes"] = merge_named(images["spec"].get("volumes", []),
                                           publisher["spec"].get("volumes", []), "name")
    jobs.remove(publisher)
    write_jobs(path, document)
    if bootstrap is not None:
        sources = (CONFIG, STEP + "-ref.yaml", STEP + "-commands.sh",
                   "hack/generators/scos-art-publication.py")
        manifest = "".join("# source " + hashlib.sha256((root / source).read_bytes()).hexdigest()
                           + " " + source + "\n" for source in sources)
        relative = "openshift/os/openshift-os-master-postsubmits.yaml"
        patch = manifest + "".join(difflib.unified_diff(
            original.splitlines(keepends=True), path.read_text().splitlines(keepends=True),
            fromfile="a/" + relative, tofile="b/" + relative))
        if check_bootstrap:
            if bootstrap.read_text() != patch:
                raise ValueError("Regenerate the portable publication overlay with make jobs")
        else:
            bootstrap.write_text(patch)


def generate_validation(jobs_root):
    """Own the environment of the existing, non-prowgen generated-config guard."""
    path = jobs_root / "openshift/release/openshift-release-main-presubmits.yaml"
    if not path.exists():
        return
    document = yaml.safe_load(path.read_text())
    matches = [job for job in document["presubmits"]["openshift/release"]
               if job["name"] == "pull-ci-openshift-release-main-generated-config"]
    if len(matches) != 1:
        raise ValueError("Expected exactly one generated-config guard")
    job = matches[0]
    container = job["spec"]["containers"][0]
    original_command = ["hack/validate-generated-config.sh"]
    ready_command = ["/bin/bash", "-ceu", VALIDATION_WAIT, "--"]
    if ((container["command"], container["args"]) not in
            ((original_command, ["./"]), (ready_command, original_command + ["./"]))):
        raise ValueError("Unexpected generated-config command")
    original = "quay.io/openshift/ci-public:ci_ci-operator-prowgen_latest"
    runtime = "quay.io/openshift/ci-public:ci_ci-operator-checkconfig_latest"
    if container["image"] not in (original, runtime):
        raise ValueError("Unexpected generated-config image")
    tools_mount = {"name": "generated-config-tools", "mountPath": "/validation-tools"}
    copier = {
        "name": "validation-tools", "image": original, "imagePullPolicy": "Always",
        "command": ["/bin/sh", "-ceu", "cp /usr/bin/ci-operator-prowgen /usr/bin/diff /validation-tools/ && touch /validation-tools/ready"],
        "resources": {"requests": {"cpu": "10m"}}, "volumeMounts": [tools_mount],
    }
    container["name"] = "test"
    container["command"] = ready_command
    container["args"] = original_command + ["./"]
    job["spec"]["volumes"] = merge_named(job["spec"].get("volumes", []),
                                         [{"name": "generated-config-tools", "emptyDir": {}}], "name")
    container["image"] = runtime
    container["volumeMounts"] = merge_named(container.get("volumeMounts", []),
                                             [dict(tools_mount, readOnly=True)], "name")
    container["env"] = merge_named(container.get("env", []), [{"name": "PATH", "value":
        "/validation-tools:/usr/local/sbin:/usr/local/bin:/usr/sbin:/usr/bin:/sbin:/bin"}], "name")
    job["spec"]["containers"] = merge_named(job["spec"]["containers"], [copier], "name")
    checkout = job["decoration_config"]["sparse_checkout_files"]
    generator = "./hack/generators/scos-art-publication.py"
    if generator not in checkout:
        checkout.append(generator)
    bootstrap = "./hack/generators/scos-art-publication.patch"
    if bootstrap not in checkout:
        checkout.append(bootstrap)
    job["run_if_changed"] = (r"^(ci-operator/(config|jobs)/.*|"
                             r"ci-operator/step-registry/openshift/os-publish-art/.*|"
                             r"hack/(generators/scos-art-publication\.(py|patch)|validate-generated-config\.sh)|Makefile)$")
    write_jobs(path, document)


def main():
    """Apply the ordered phase only when prowgen selected this source configuration."""
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--release-root", type=Path, required=True)
    parser.add_argument("--jobs-root", type=Path, required=True)
    parser.add_argument("--bootstrap", type=Path)
    parser.add_argument("--check-bootstrap", action="store_true")
    parser.add_argument("--selection", nargs=argparse.REMAINDER, default=[])
    arguments = parser.parse_args()
    selected = []
    directories = []
    organization = ""
    repository = ""
    for index, option in enumerate(arguments.selection):
        if option.startswith("-") and not option.startswith("--"):
            option = "-" + option
        if option.startswith(("--only-process-changes", "--managed-repos-config", "--to-dir", "--to-release-repo")):
            parser.error("Ordered publication requires explicit source selection, not output or dynamic ownership overrides")
        if option.startswith("--from-file="):
            selected.append(Path(option.split("=", 1)[1]).resolve())
        elif option == "--from-file":
            selected.append(Path(arguments.selection[index + 1]).resolve())
        elif option.startswith("--from-dir="):
            directories.append(Path(option.split("=", 1)[1]).resolve())
        elif option == "--from-dir":
            directories.append(Path(arguments.selection[index + 1]).resolve())
        elif option.startswith("--org="):
            organization = option.split("=", 1)[1]
        elif option == "--org":
            organization = arguments.selection[index + 1]
        elif option.startswith("--repo="):
            repository = option.split("=", 1)[1]
        elif option == "--repo":
            repository = arguments.selection[index + 1]
    def coreos():
        if arguments.bootstrap is None:
            generate(arguments.release_root, arguments.jobs_root)
        else:
            generate(arguments.release_root, arguments.jobs_root, arguments.bootstrap, arguments.check_bootstrap)

    for source_path, action in ((CONFIG, coreos),
                                (VALIDATION_CONFIG, lambda: generate_validation(arguments.jobs_root))):
        source = (arguments.release_root / source_path).resolve()
        if organization and source.parent.parent.name != organization:
            continue
        if repository and source.parent.name != repository:
            continue
        if selected and source not in selected:
            continue
        if directories and not any(directory in source.parents for directory in directories):
            continue
        action()


if __name__ == "__main__":
    main()
