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
config = {}
state = {"phase": "inputs", "upload": "not attempted"}


def save_status():
    temporary = work / "upload-status.tmp"
    temporary.write_text(json.dumps(state, indent=2) + "\n")
    temporary.replace(work / "upload-status.json")


def phase(name):
    state["phase"] = name
    save_status()


def log_output(output):
    if isinstance(output, bytes):
        output = output.decode("utf-8", errors="replace")
    output = output or ""
    request = re.search(r"Request:([0-9a-fA-F-]{36})\b", output)
    if request:
        state["request_id"] = request.group(1)
    # Raw output remains private; only allowlisted status fields are published.
    for key in ("username", "password"):
        secret = config.get(key)
        if isinstance(secret, str) and secret:
            output = output.replace(secret, "[REDACTED]")
    with (work / "upload.log").open("a") as stream:
        stream.write("[" + state["phase"] + "]\n" + output + "\n")
    return output.lower()


def run(args, timeout):
    result = subprocess.run(args, stdout=subprocess.PIPE, stderr=subprocess.STDOUT,
                            text=True, errors="replace", timeout=timeout, check=False)
    if result.returncode:
        raise subprocess.CalledProcessError(result.returncode, args, output=result.stdout)
    log_output(result.stdout)
    return result.stdout


try:
    phase("inputs")
    config = json.loads(config_file.read_text())
    config_file.unlink()
    repo = work / "reporter"
    phase("clone")
    run(["git", "clone", "--depth", "1", "--recursive", config["repository"], str(repo)], 180)
    os.chdir(repo)
    phase("revision")
    revision = run(["git", "rev-parse", "HEAD"], 30).strip()
    if not re.fullmatch(r"[0-9a-f]{40}", revision):
        raise ValueError("Invalid reporter revision")
    state["reporter_revision"] = revision
    phase("import")
    sys.dont_write_bytecode = True
    sys.path.insert(0, str(repo / "cnf-polarion"))
    spec = importlib.util.spec_from_file_location(
        "rp_upload", repo / "cnf-polarion/upload_to_report_portal.py")
    uploader = importlib.util.module_from_spec(spec)
    spec.loader.exec_module(uploader)
    phase("metadata")
    results = work / "results"
    uploader.data_router_report_portal_config(
        str(results), config["version"], config["launch"],
        config["description"], config["attributes"])
    metadata = results / "datarouter_report_portal.json"
    targets = json.loads(metadata.read_text())["targets"]
    if set(targets) != {"reportportal"}:
        raise ValueError("Unexpected upload destination")
    expected_host = targets["reportportal"]["config"]["hostname"]
    state["upload"] = "completion unconfirmed"
    phase("upload")
    output = run(
        ["drouter/droute-linux-386", "send", "-v",
         "--url", "https://datarouter.dno.corp.redhat.com",
         "--username", config["username"], "--password", config["password"],
         "--metadata=" + str(metadata), "--wait",
         "--results=" + str(results / "*.xml")], 600)
    state["client_exit_code"] = 0
    phase("response")
    urls = {json.loads(value) for value in re.findall(
        r'"launch_url"\s*:\s*("(?:[^"\\]|\\.)*")', output)}
    state["launch_url_count"] = len(urls)
    if len(urls) != 1:
        raise ValueError("Upload did not return one launch URL")
    url = urls.pop()
    parsed = urlsplit(url)
    if (parsed.scheme != "https" or parsed.hostname != expected_host or
            parsed.username or parsed.password):
        raise ValueError("Unexpected launch URL")
    state.update(phase="complete", upload="completed", url=url)
except Exception as error:
    state["error_type"] = type(error).__name__
    if isinstance(error, subprocess.CalledProcessError):
        state["exit_code"] = error.returncode
        if state["phase"] == "upload":
            state["client_exit_code"] = error.returncode
        detail = log_output(error.output)
    elif isinstance(error, subprocess.TimeoutExpired):
        state["timeout_seconds"] = error.timeout
        detail = log_output(error.stdout)
    else:
        detail = log_output(str(error))
    if isinstance(error, ModuleNotFoundError) and error.name:
        state["missing_module"] = error.name
    if isinstance(error, OSError) and error.errno is not None:
        state["errno"] = error.errno
    # Recognized messages become fixed public codes, never arbitrary log text.
    for reason, patterns in (
        ("tls_verification", ("certificate verify failed", "ssl certificate problem", "server certificate verification failed")),
        ("authentication", ("authentication failed", "authentication required", "invalid username/password", "401 unauthorized")),
        ("dns_resolution", ("could not resolve host", "name or service not known", "temporary failure in name resolution")),
        ("connection_refused", ("connection refused",)),
        ("permission_denied", ("permission denied", "403 forbidden")),
    ):
        if any(pattern in detail for pattern in patterns):
            state["reason"] = reason
            break
    print("IBI reporter failed during " + state["phase"] + " (" + state["error_type"] + ").", file=sys.stderr)
finally:
    save_status()
sys.exit(0 if state["upload"] == "completed" else 1)
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


class CommandError(RuntimeError):
    def __init__(self, label, **details):
        super().__init__(label + " failed")
        self.details = {"command": label, **details}


def command(args, label, timeout=180, text=None):
    try:
        result = subprocess.run(args, input=text, text=True, stdout=subprocess.PIPE,
                                stderr=subprocess.PIPE, timeout=timeout, check=False)
    except subprocess.TimeoutExpired:
        raise CommandError(label, timeout_seconds=timeout) from None
    except OSError as error:
        raise CommandError(label, errno=error.errno) from None
    if result.returncode:
        raise CommandError(label, exit_code=result.returncode)
    return result.stdout


def read_upload_status(path):
    # The private file is never copied wholesale into public Prow artifacts.
    value = json.loads(path.read_text())
    if value.get("phase") not in ("inputs", "clone", "revision", "import", "metadata", "upload", "response", "complete"):
        raise ValueError("Invalid reporter phase")
    if value.get("upload") not in ("not attempted", "completion unconfirmed", "completed"):
        raise ValueError("Invalid upload outcome")
    public = {key: value[key] for key in ("phase", "upload")}
    for key, pattern in {
        "error_type": r"[A-Za-z_][A-Za-z0-9_]{0,79}",
        "missing_module": r"[A-Za-z_][A-Za-z0-9_.]{0,199}",
        "reporter_revision": r"[0-9a-f]{40}",
        "request_id": r"[0-9a-fA-F]{8}(?:-[0-9a-fA-F]{4}){3}-[0-9a-fA-F]{12}",
        "reason": r"tls_verification|authentication|dns_resolution|connection_refused|permission_denied",
    }.items():
        if key in value:
            if not isinstance(value[key], str) or not re.fullmatch(pattern, value[key]):
                raise ValueError("Invalid reporter diagnostic field")
            public[key] = value[key]
    for key in ("exit_code", "client_exit_code", "timeout_seconds", "errno", "launch_url_count"):
        if key in value:
            if type(value[key]) is not int:
                raise ValueError("Invalid reporter numeric diagnostic")
            public[key] = value[key]
    if value["upload"] == "completed":
        url = value.get("url", "")
        parsed = urlsplit(url)
        if (value["phase"] != "complete" or not public.get("reporter_revision") or
                value.get("client_exit_code") != 0 or value.get("launch_url_count") != 1 or
                parsed.scheme != "https" or not parsed.hostname or parsed.username or parsed.password):
            raise ValueError("Invalid completed upload status")
        public["url"] = url
    return public


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
            try:
                command(["ssh", *opts, target, "python3 - " + shlex.quote(remote)],
                        "Run reporter", timeout=900, text=REMOTE_UPLOADER)
            except CommandError as error:
                summary["reporter_transport"] = error.details
                # A disconnected SSH session does not prove that upload failed.
            finally:
                try:
                    command(["scp", "-q", *opts, target + ":" + remote + "/upload-status.json",
                             str(scratch / "upload-status.json")], "Collect reporter status")
                    result = read_upload_status(scratch / "upload-status.json")
                    summary["reporter"] = result
                    summary["upload"] = result["upload"]
                    (artifacts / "upload-status.json").write_text(json.dumps(result, indent=2) + "\n")
                    if result["upload"] == "completed":
                        (artifacts / "reportportal-url.txt").write_text(result["url"] + "\n")
                        (shared / "ibi-reportportal-url").write_text(result["url"] + "\n")
                        summary["reporter_revision"] = result["reporter_revision"]
                        print("ReportPortal upload completed; launch URL saved in artifacts.")
                    else:
                        print("IBI reporter last recorded phase: " + result["phase"] +
                              "; see upload-status.json.", file=sys.stderr)
                except Exception as error:
                    summary["status_collection_error"] = (error.details if isinstance(error, CommandError)
                                                          else {"error_type": type(error).__name__})
                    problems.append("reporter status")
        finally:
            # Keep credential cleanup errors separate from the upload outcome.
            try:
                command(["ssh", *opts, target,
                         "rm -f -- " + shlex.quote(remote + "/upload.json")],
                        "Remove private upload inputs")
                summary["credential_cleanup"] = "completed"
            except CommandError as error:
                summary["credential_cleanup"] = error.details
                problems.append("credential cleanup")
        return 1 if problems or summary["upload"] != "completed" else 0


status = 1
try:
    status = main()
except Exception as error:
    summary["error"] = (error.details if isinstance(error, CommandError)
                        else {"error_type": type(error).__name__})
    print("IBI reporting failed; see reporting-status.json and the private bastion reports.",
          file=sys.stderr)
finally:
    (artifacts / "reporting-status.json").write_text(json.dumps(summary, indent=2) + "\n")
sys.exit(status)
PY
