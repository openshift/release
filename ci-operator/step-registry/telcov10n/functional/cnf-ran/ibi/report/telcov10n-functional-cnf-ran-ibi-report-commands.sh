#!/bin/bash
set +x
set -euo pipefail
umask 077

if [[ -f "${SHARED_DIR}/skip.txt" ]]; then
  echo "Skipping IBI ReportPortal upload."
  exit 0
fi

python3 - <<'PY'
REMOTE_UPLOADER = r'''
import importlib.util
import json
import os
import re
import subprocess
import sys
from pathlib import Path
from urllib.parse import urlsplit

work = Path(sys.argv[1])
config_file = work / "upload.json"
os.umask(0o077)
config = json.loads(config_file.read_text())
config_file.unlink()
phase = "reporter preparation"
try:
    repo = work / "reporter"
    subprocess.run(["git", "clone", "--depth", "1", "--recursive",
                    config["repository"], str(repo)],
                   stdout=subprocess.PIPE, stderr=subprocess.STDOUT,
                   timeout=180, check=True)
    os.chdir(repo)
    sys.path.insert(0, str(repo / "cnf-polarion"))
    spec = importlib.util.spec_from_file_location(
        "rp_upload", repo / "cnf-polarion/upload_to_report_portal.py")
    uploader = importlib.util.module_from_spec(spec)
    spec.loader.exec_module(uploader)
    results = work / "results"
    uploader.data_router_report_portal_config(
        str(results), config["version"], config["launch"],
        config["description"], config["attributes"])
    metadata = results / "datarouter_report_portal.json"
    targets = json.loads(metadata.read_text())["targets"]
    if set(targets) != {"reportportal"}:
        raise ValueError("Unexpected upload destination")
    expected_host = targets["reportportal"]["config"]["hostname"]
    phase = "ReportPortal upload"
    result = subprocess.run(
        ["drouter/droute-linux-386", "send", "-v",
         "--url", "https://datarouter.dno.corp.redhat.com",
         "--username", config["username"], "--password", config["password"],
         "--metadata=" + str(metadata), "--wait",
         "--results=" + str(results / "*.xml")],
        stdout=subprocess.PIPE, stderr=subprocess.STDOUT,
        text=True, timeout=600, check=False)
    # Keep diagnostic output private and remove credentials before saving it.
    output = result.stdout
    for secret in (config["username"], config["password"]):
        output = output.replace(secret, "[REDACTED]")
    (work / "upload.log").write_text(output)
    urls = {json.loads(value) for value in re.findall(
        r'"launch_url"\s*:\s*("(?:[^"\\]|\\.)*")', result.stdout)}
    if result.returncode != 0 or len(urls) != 1:
        raise RuntimeError("Upload failed or did not return one launch URL")
    url = urls.pop()
    if urlsplit(url).scheme != "https" or urlsplit(url).hostname != expected_host:
        raise ValueError("Unexpected launch URL")
    revision = subprocess.check_output(
        ["git", "rev-parse", "HEAD"], text=True).strip()
    print(json.dumps({"url": url, "reporter_revision": revision}))
except Exception as error:
    (work / "upload-error.txt").write_text(
        phase + " failed: " + type(error).__name__ +
        "; completion is unconfirmed. Check ReportPortal before retrying.\n")
    # Exception/argv and clone output may contain credentials.
    print("ReportPortal upload failed; inspect the private bastion work directory.",
          file=sys.stderr)
    sys.exit(1)
'''
import json
import os
import re
import shlex
import shutil
import subprocess
import sys
import tempfile
import xml.etree.ElementTree as ET
from pathlib import Path
from urllib.parse import urlsplit

import yaml

shared = Path(os.environ["SHARED_DIR"])
artifacts = Path(os.environ["ARTIFACT_DIR"]) / "reportportal"
artifacts.mkdir(parents=True, exist_ok=True)
stages = (
    ("seedgen", "seed", r"/tmp/eco_gotests/report"),
    ("preinstall", "target", r"/tmp/eco_gotests_ibi_preinstall/ibi-preinstall\.[A-Za-z0-9]+/report"),
    ("ibi", "target", r"/tmp/eco_gotests_ibi_deploymenttypes/ibi-deploymenttypes\.[A-Za-z0-9]+/report"),
    ("preinstall_replacement", "seed", r"/tmp/eco_gotests_ibi_preinstall/ibi-replacement-preinstall\.[A-Za-z0-9]+/report"),
    ("ibbf", "target", r"/tmp/eco_gotests_ibi_ibbf/ibi-ibbf\.[A-Za-z0-9]+/report"),
)
summary = {"stages": {}, "upload": "not attempted"}
problems = []


def inventory(prefix):
    values = {}
    for suffix in ("all", "bastions", "bastion"):
        values.update(yaml.safe_load((shared / (prefix + "-" + suffix)).read_text()))
    return values


def destination(prefix):
    values = inventory(prefix)
    host, user = values["ansible_host"], values["ansible_user"]
    if not re.fullmatch(r"[A-Za-z0-9][A-Za-z0-9.:-]*", host):
        raise ValueError("Invalid bastion host")
    if not re.fullmatch(r"[A-Za-z_][A-Za-z0-9_-]*", user):
        raise ValueError("Invalid bastion user")
    return user + "@" + host


def command(args, label, timeout=180, text=None):
    result = subprocess.run(args, input=text, text=True, stdout=subprocess.PIPE,
                            stderr=subprocess.PIPE, timeout=timeout, check=False)
    if result.returncode:
        raise RuntimeError(label + " failed")
    return result.stdout


def normalize(path, lane, output):
    tree = ET.parse(path)
    root = tree.getroot()
    if root.tag not in ("testsuite", "testsuites"):
        raise ValueError("Not JUnit XML")
    suites = list(root.iter("testsuite"))
    if not suites or not list(root.iter("testcase")):
        raise ValueError("Empty JUnit report")
    for suite in suites:
        suite.set("name", "[" + lane + "] " + suite.get("name", path.stem))
        props = suite.find("properties")
        if props is None:
            props = ET.Element("properties")
            suite.insert(0, props)
        ET.SubElement(props, "property", name="ci-lane", value=lane)
    tree.write(output, encoding="utf-8", xml_declaration=True)


def main():
    if not any((shared / ("ibi-rp-" + lane + "-dir")).exists()
               for lane, _, _ in stages):
        summary["upload"] = "skipped: no test stage registered a report directory"
        return 0

    with tempfile.TemporaryDirectory(prefix="ibi-reportportal.") as local:
        scratch = Path(local)
        key = scratch / "ssh-key"
        shutil.copyfile("/var/group_variables/common/all/ansible_ssh_private_key", key)
        key.chmod(0o600)
        opts = ["-i", str(key), "-o", "BatchMode=yes", "-o", "ConnectTimeout=30",
                "-o", "ServerAliveInterval=30", "-o", "ServerAliveCountMax=6",
                "-o", "StrictHostKeyChecking=no", "-o", "UserKnownHostsFile=/dev/null"]
        ready = scratch / "results"
        ready.mkdir()
        for lane, prefix, allowed in stages:
            pointer = shared / ("ibi-rp-" + lane + "-dir")
            if not pointer.exists():
                summary["stages"][lane] = "not reached or disabled"
                continue
            source = scratch / lane
            source.mkdir()
            try:
                directory = pointer.read_text().strip()
                if not re.fullmatch(allowed, directory):
                    raise ValueError("Invalid report directory")
                host = destination(prefix)
                command(["scp", "-q", *opts,
                         host + ":" + directory + "/*_suite_test_junit.xml",
                         str(source)], lane + " report collection")
                reports = list(source.glob("*_suite_test_junit.xml"))
                if len(reports) != 1:
                    raise ValueError("Expected one raw suite report")
                normalize(reports[0], lane, ready / (lane + "-" + reports[0].name))
                if lane == "ibbf":
                    gate = source / "junit_ibbf_policy_gate.xml"
                    try:
                        command(["scp", "-q", *opts,
                                 host + ":" + directory + "/" + gate.name,
                                 str(gate)], "IBBF policy report collection")
                    except RuntimeError:
                        hardware = ET.parse(reports[0])
                        passed = any("78333" in c.get("name", "") and
                                     not any(c.find(tag) is not None
                                             for tag in ("failure", "error", "skipped"))
                                     for c in hardware.iter("testcase"))
                        if passed:
                            raise ValueError("Policy report missing after passing IBBF")
                    else:
                        normalize(gate, lane, ready / (lane + "-" + gate.name))
                summary["stages"][lane] = "collected"
            except Exception:
                # Preserve other available stages, but fail this reporting step.
                summary["stages"][lane] = "report missing, invalid, or inaccessible"
                problems.append(lane)

        reports = sorted(ready.glob("*.xml"))
        if not reports:
            raise RuntimeError("No valid current-run reports available")
        summary["files"] = [p.name for p in reports]
        values = inventory("target")
        version = os.environ["VERSION"]
        if not re.fullmatch(r"[0-9]+\.[0-9]+", version):
            raise ValueError("Invalid release family")
        repository = values["reporter_project_git"]
        parsed = urlsplit(repository)
        if parsed.scheme != "https" or not parsed.hostname or parsed.username or parsed.password:
            raise ValueError("Invalid reporter repository")
        build = os.environ.get("BUILD_ID", "unknown")
        seed_version = (shared / "ibi-seed-version").read_text().strip()
        config = {
            "repository": repository,
            "username": values["report_router_user"],
            "password": values["report_router_pass"],
            "launch": os.environ["IBI_REPORTPORTAL_LAUNCH_NAME"],
            "version": version,
            "description": "Prow build " + build + "; OCP " + seed_version +
                           "; stage collection: " + json.dumps(summary["stages"]),
            "attributes": "ci:prow;ocp_version:" + seed_version + ";build_id:" + build,
        }
        if any(not isinstance(v, str) or not v or "{{" in v for v in config.values()):
            raise ValueError("Unresolved reporter inputs")
        target = destination("target")
        remote = command(["ssh", *opts, target,
                          "umask 077; mktemp -d /tmp/ibi-reportportal.XXXXXX"],
                         "Create report directory").strip()
        if not re.fullmatch(r"/tmp/ibi-reportportal\.[A-Za-z0-9]+", remote):
            raise ValueError("Invalid upload directory")
        summary["bastion_report_directory"] = remote
        private = scratch / "upload.json"
        private.write_text(json.dumps(config))
        private.chmod(0o600)
        try:
            command(["scp", "-q", "-r", *opts, str(ready), str(private),
                     target + ":" + remote + "/"], "Upload staging")
            summary["upload"] = "completion unconfirmed"
            response = command(
                ["ssh", *opts, target, "python3 - " + shlex.quote(remote)],
                "ReportPortal upload", timeout=900, text=REMOTE_UPLOADER)
            result = json.loads(response)
            (artifacts / "reportportal-url.txt").write_text(result["url"] + "\n")
            (shared / "ibi-reportportal-url").write_text(result["url"] + "\n")
            summary["upload"] = "completed"
            summary["reporter_revision"] = result["reporter_revision"]
            print("ReportPortal upload completed; launch URL saved in artifacts.")
        finally:
            # The remote uploader also removes this before starting.
            command(["ssh", *opts, target,
                     "rm -f -- " + shlex.quote(remote + "/upload.json")],
                    "Remove private upload inputs")
        return 1 if problems else 0


status = 1
try:
    status = main()
except Exception:
    print("IBI reporting failed; see reporting-status.json and the private bastion reports.",
          file=sys.stderr)
finally:
    (artifacts / "reporting-status.json").write_text(json.dumps(summary, indent=2) + "\n")
sys.exit(status)
PY
