#!/bin/bash
set +x
set +e
umask 077
mkdir -p "${ARTIFACT_DIR}/cluster-diagnostics"
printf '%s\n' '{"collector":"unavailable","action":"Check Python availability and step completion"}' > "${ARTIFACT_DIR}/cluster-diagnostics/collection-outcome.json"
OCM_TOKEN=""
if [[ -f /usr/local/cs-qe-credentials/ocm-tokens ]]; then
  source /usr/local/cs-qe-credentials/ocm-tokens >/dev/null 2>&1 || true
fi
if [[ -z "${OCM_TOKEN:-}" && -f /usr/local/cs-qe-credentials/ocm_token ]]; then
  OCM_TOKEN="$(cat /usr/local/cs-qe-credentials/ocm_token)"
fi
export OCM_TOKEN
python3 - <<'PY'
import datetime
import json
import os
from pathlib import Path
import re
import resource
import signal
import stat
import subprocess
import tempfile
import time
import urllib.parse


LIMIT = 1024 * 1024
DEADLINE = time.monotonic() + 450
DIAG = Path(os.environ["ARTIFACT_DIR"]) / "cluster-diagnostics"
SHARED = Path(os.environ["SHARED_DIR"])
OUTCOME = {
    "collector": "started",
    "operator_logs": "unsupported: no predefined authorized operator-log path in this step",
    "action": "Inspect identity handoff and CMS API permissions; pending alone is not terminal",
}
STATES = {"pending", "installing", "ready", "error", "uninstalling", "powering_down",
          "hibernating", "resuming", "PendingProject", "Pending", "Ready", "Error",
          "Failed", "Claimed", "Unclaimed", "Creating", "Available", "Verification", "Running", "Succeeded"}
CONDITIONS = {"Ready", "Available", "Progressing", "Degraded", "RequirementsMet",
              "Claimed", "Error", "Failed", "Pending", "Verification", "Invalid", "ComputeApiReady"}
KINDS = {"AccountClaim", "ProjectClaim", "ProjectReference", "Project", "ClusterDeployment", "Cluster"}
IDENTIFIER = re.compile(r"[a-z0-9]{20,64}")
NAME = re.compile(r"[a-z][a-z0-9-]{1,61}[a-z0-9]")


def artifact(name, data):
    (DIAG / name).write_text(json.dumps(data, indent=2) + "\n", encoding="utf-8")


def command(arguments, seconds=20):
    remaining = DEADLINE - time.monotonic()
    if remaining <= 0:
        OUTCOME["budget"] = "exhausted"
        return None, "budget_exhausted"
    try:
        with tempfile.TemporaryFile() as output:
            def child_limits():
                file_limit = 200 * LIMIT if arguments[0] in ("curl", "tar") else LIMIT
                resource.setrlimit(resource.RLIMIT_FSIZE, (file_limit, file_limit))
                if arguments[0] == "tar":
                    resource.setrlimit(resource.RLIMIT_AS, (128 * LIMIT, 128 * LIMIT))

            process = subprocess.Popen(arguments, stdout=output, stderr=subprocess.DEVNULL,
                                       preexec_fn=child_limits, start_new_session=True)
            try:
                process.wait(timeout=min(seconds, remaining))
            finally:
                try:
                    os.killpg(process.pid, signal.SIGKILL)
                except ProcessLookupError:
                    pass
                process.wait(timeout=5)
            if process.returncode:
                return None, "command_failed"
            if output.tell() >= LIMIT:
                return None, "response_too_large"
            output.seek(0)
            return output.read(LIMIT), "ok"
    except FileNotFoundError:
        return None, "tool_unavailable"
    except subprocess.TimeoutExpired:
        return None, "timeout"
    except OSError:
        return None, "command_failed"


def get_json(path):
    data, outcome = command(["ocm", "get", path])
    if outcome != "ok":
        return None, outcome
    try:
        value = json.loads(data)
        return (value, "ok") if isinstance(value, dict) else (None, "invalid_response")
    except (ValueError, UnicodeError):
        return None, "invalid_response"


def local_file(name):
    path = SHARED / name
    if path.is_symlink() or not path.is_file() or path.stat().st_size > 16384:
        raise ValueError("invalid_identity_file")
    return path.read_text(encoding="utf-8")


def identity():
    identifiers = set()
    for name in ("cluster-id", "ocm-fvt-cluster-ids"):
        if (SHARED / name).exists() or (SHARED / name).is_symlink():
            for value in local_file(name).split():
                if not IDENTIFIER.fullmatch(value):
                    raise ValueError("malformed_identity")
                identifiers.add(value)
    if len(identifiers) > 1:
        raise ValueError("ambiguous_identity")
    if not (SHARED / "ocm-fvt-diagnostic-identity.json").exists():
        if identifiers:
            OUTCOME["identity"] = "shared_id"
            return identifiers.pop()
        raise ValueError("missing_identity: preserve run-bound FVT identity handoff")
    manifest = json.loads(local_file("ocm-fvt-diagnostic-identity.json"))
    if not isinstance(manifest, dict) or manifest.get("outcome") != "ok":
        raise ValueError("invalid_identity_handoff")
    run = os.environ.get("BUILD_ID", "")
    if (not run or not os.environ.get("JOB_NAME") or manifest.get("run") != run
            or manifest.get("job") != os.environ.get("JOB_NAME")):
        raise ValueError("unscoped_identity")
    names = manifest.get("names")
    recorded_ids = manifest.get("ids")
    if (not isinstance(names, list) or len(names) > 1 or not isinstance(recorded_ids, list)
            or len(recorded_ids) > 1):
        raise ValueError("ambiguous_or_missing_name")
    if names and (not isinstance(names[0], str) or not NAME.fullmatch(names[0])):
        raise ValueError("malformed_name")
    if recorded_ids and (not isinstance(recorded_ids[0], str) or not IDENTIFIER.fullmatch(recorded_ids[0])):
        raise ValueError("malformed_identity")
    identifiers.update(recorded_ids)
    if len(identifiers) > 1:
        raise ValueError("identity_mismatch")
    if not identifiers:
        raise ValueError("unverified_name_identity" if names else "missing_identity: preserve run-bound FVT identity handoff")
    expected_id = identifiers.pop()
    started, finished = manifest.get("started"), manifest.get("finished")
    if (type(started) is not int or type(finished) not in (int, float) or
            not 0 < started <= finished <= time.time() + 60 or finished - started > 86400):
        raise ValueError("invalid_run_window")
    if recorded_ids:
        OUTCOME["identity"] = "recorded_id"
        if not names:
            return expected_id
    elif not names:
        OUTCOME["identity"] = "shared_id"
        return expected_id
    query = urllib.parse.urlencode({"search": "name = '" + names[0] + "'", "size": 2})
    response, status = get_json("/api/clusters_mgmt/v1/clusters?" + query)
    if status != "ok":
        raise ValueError("identity_lookup_" + status)
    items = response.get("items")
    if (response.get("total") != 1 or not isinstance(items, list) or len(items) != 1
            or not isinstance(items[0], dict)):
        raise ValueError("ambiguous_or_missing_match")
    cluster = items[0]
    cluster_id = cluster.get("id", "")
    if cluster.get("name") != names[0] or cluster_id != expected_id:
        raise ValueError("invalid_identity_match")
    try:
        created = datetime.datetime.fromisoformat(cluster["creation_timestamp"].replace("Z", "+00:00"))
        if created.tzinfo is None or not started <= created.timestamp() <= finished:
            raise ValueError()
    except (KeyError, TypeError, AttributeError, ValueError):
        raise ValueError("unscoped_creation_time") from None
    OUTCOME["identity"] = "unique_run_name"
    return cluster_id


def summary(value):
    result = {}
    if not isinstance(value, dict):
        return {"outcome": "invalid_response"}
    for key in ("state", "phase", "provision_status"):
        if isinstance(value.get(key), str):
            result[key] = value[key] if value[key] in STATES else "other"
    for key in ("dns_ready", "oidc_ready"):
        if type(value.get(key)) is bool:
            result[key] = value[key]
    if "provision_error_code" in value:
        result["provision_error_present"] = bool(value["provision_error_code"])
    if isinstance(value.get("containerStatuses"), list):
        result["container_restarts"] = sum(
            min(container["restartCount"], 1000000) for container in value["containerStatuses"][:16]
            if isinstance(container, dict) and type(container.get("restartCount")) is int
            and container["restartCount"] >= 0)
    if isinstance(value.get("conditions"), list):
        result["conditions"] = [
            {"type": condition["type"], "status": condition["status"],
             "reconcile_error": condition.get("reason") == "ReconcileError"}
            for condition in value["conditions"][:32] if isinstance(condition, dict)
            and isinstance(condition.get("type"), str) and condition["type"] in CONDITIONS
            and condition.get("status") in ("True", "False", "Unknown")
        ]
    return result or {"outcome": "empty_or_unrecognized_status"}


def preinstall(cluster_id):
    root = "/api/clusters_mgmt/v1/clusters/" + cluster_id
    for label, suffix in (("cluster", ""), ("cluster-status", "/status")):
        value, status = get_json(root + suffix)
        artifact(label + ".json", summary(value) if status == "ok" else {"outcome": status})
    value, status = get_json(root + "/resources/live")
    result = {"outcome": status, "resources": []}
    if status == "ok":
        resources = value.get("resources")
        if value.get("cluster_id") != cluster_id:
            result["outcome"] = "identity_mismatch"
        elif not isinstance(resources, dict) or len(resources) > 32:
            result["outcome"] = "invalid_response"
        else:
            for encoded in resources.values():
                try:
                    observed = json.loads(encoded)
                    if (not isinstance(observed, dict) or not isinstance(observed.get("kind"), str)
                            or observed["kind"] not in KINDS):
                        continue
                    item = {"kind": observed["kind"], "status": summary(observed.get("status"))}
                    spec = observed.get("spec")
                    if isinstance(spec, dict):
                        links = [spec.get(key) for key in ("accountLink", "projectReferenceCRLink", "projectClaimCRLink")]
                        item["reference_present"] = any(
                            (isinstance(link, str) and bool(link)) or
                            (isinstance(link, dict) and isinstance(link.get("name"), str) and bool(link["name"])
                             and isinstance(link.get("namespace"), str) and bool(link["namespace"])) for link in links)
                    result["resources"].append(item)
                except (TypeError, ValueError):
                    result["outcome"] = "invalid_resource"
            if not result["resources"] and result["outcome"] == "ok":
                result["outcome"] = "no_supported_resources"
    artifact("preinstall-resources.json", result)


def install_tools(work):
    version = os.environ.get("GATHER_OCM_CLI_VERSION", "1.0.15")
    if not re.fullmatch(r"[0-9]+\.[0-9]+\.[0-9]+", version):
        return "invalid_tool_version"
    binary = work / "ocm"
    _, status = command(["curl", "-sSL", "--fail", "--connect-timeout", "10", "--max-time", "60",
                         "-o", str(binary), "https://github.com/openshift-online/ocm-cli/releases/download/v"
                         + version + "/ocm-linux-amd64"], 65)
    if status == "ok":
        binary.chmod(0o700)
    return status


def guest(cluster_id, work):
    version = os.environ.get("GATHER_BACKPLANE_CLI_VERSION", "0.11.0")
    if not re.fullmatch(r"[0-9]+\.[0-9]+\.[0-9]+", version):
        OUTCOME["guest"] = "invalid_tool_version"
        return
    archive = work / "backplane.tar.gz"
    _, status = command(["curl", "-sSL", "--fail", "--connect-timeout", "10", "--max-time", "60",
                         "-o", str(archive), "https://github.com/openshift/backplane-cli/releases/download/v"
                         + version + "/ocm-backplane_" + version + "_Linux_x86_64.tar.gz"], 65)
    if status == "ok":
        _, status = command(["tar", "-xzf", str(archive), "-C", str(work), "--no-same-owner",
                             "--no-same-permissions", "--keep-old-files", "--", "ocm-backplane"])
        if status == "ok":
            binary = work / "ocm-backplane"
            metadata = binary.lstat()
            if not stat.S_ISREG(metadata.st_mode) or metadata.st_nlink != 1 or metadata.st_size > 200 * LIMIT:
                raise ValueError("invalid_tool_archive")
            binary.chmod(0o700)
    config = work / "backplane-config.json"
    config.write_text(json.dumps({"proxy-url": os.environ.get("GATHER_BACKPLANE_PROXY_URL", "")}))
    os.environ["BACKPLANE_CONFIG"] = str(config)
    kubeconfig = work / "kubeconfig"
    os.environ["KUBECONFIG"] = str(kubeconfig)
    OUTCOME["backplane_tool"] = status
    _, access = command(["ocm-backplane", "login", cluster_id]) if status == "ok" else (None, status)
    OUTCOME["backplane_access"] = access
    if access != "ok":
        credentials, access = get_json("/api/clusters_mgmt/v1/clusters/" + cluster_id + "/credentials")
        OUTCOME["credentials_api"] = access
        if access != "ok" or not isinstance(credentials.get("kubeconfig"), str) or not credentials["kubeconfig"]:
            OUTCOME["guest"] = "access_unavailable"
            return
        kubeconfig.write_text(credentials["kubeconfig"])
    OUTCOME["guest"] = "attempted"
    for label, arguments in (
        ("oauth-apiserver-pods", ["get", "pods", "-n", "openshift-oauth-apiserver", "-o", "json"]),
        ("etcd-pods", ["get", "pods", "-n", "openshift-etcd", "-o", "json"]),
        ("co-authentication", ["get", "clusteroperator", "authentication", "-o", "json"]),
    ):
        data, status = command(["oc", "--request-timeout=15s", *arguments])
        result = {"outcome": status}
        if status == "ok":
            try:
                value = json.loads(data)
                items = value.get("items", [value])
                result["statuses"] = [summary(item.get("status")) for item in items[:16]]
                if label.endswith("-pods"):
                    namespace = "openshift-" + label.removesuffix("-pods")
                    for index, item in enumerate(items[:4]):
                        pod = item.get("metadata", {}).get("name", "")
                        if not isinstance(pod, str) or not re.fullmatch(r"[a-z0-9][a-z0-9.-]{0,252}", pod):
                            continue
                        for previous in (False, True):
                            arguments = ["oc", "--request-timeout=15s", "logs", "-n", namespace,
                                         pod, "--all-containers", "--tail=500", "--limit-bytes=65536"]
                            if previous:
                                arguments.append("--previous")
                            logs, log_status = command(arguments)
                            artifact(label + "-" + str(index) + ("-previous" if previous else "") + ".json",
                                     {"outcome": log_status, "signals": {
                                         signal: len(re.findall(pattern, logs or b"", re.IGNORECASE))
                                         for signal, pattern in (("error", rb"\berror\b"), ("panic", rb"\bpanic\b"),
                                                                 ("timeout", rb"\btimeout\b"))}})
            except (ValueError, AttributeError, TypeError):
                result = {"outcome": "invalid_response"}
        artifact(label + ".json", result)
    for namespace in ("openshift-oauth-apiserver", "openshift-etcd"):
        data, status = command(["oc", "--request-timeout=15s", "get", "events", "-n", namespace, "-o", "json"])
        result = {"outcome": status}
        if status == "ok":
            try:
                items = json.loads(data)["items"]
                if not isinstance(items, list):
                    raise ValueError()
                result["types"] = {event_type: sum(isinstance(item, dict) and item.get("type") == event_type
                                                 for item in items[:128]) for event_type in ("Normal", "Warning")}
                result["truncated"] = len(items) > 128
            except (ValueError, KeyError, TypeError):
                result = {"outcome": "invalid_response"}
        artifact(namespace + "-events.json", result)


try:
    with tempfile.TemporaryDirectory(prefix="gather-diagnostics.") as directory:
        work = Path(directory)
        os.environ["PATH"] = str(work) + os.pathsep + os.environ["PATH"]
        os.environ["OCM_CONFIG"] = str(work / "ocm-config.json")
        has_id = any((SHARED / name).exists() for name in
                     ("cluster-id", "ocm-fvt-cluster-ids", "ocm-fvt-diagnostic-identity.json"))
        if not has_id:
            raise ValueError("missing_identity: preserve run-bound FVT identity handoff")
        status = install_tools(work)
        if status != "ok":
            raise ValueError("ocm_install_" + status)
        environment = os.environ.get("GATHER_OCM_ENV", "staging")
        environment = {"stage": "staging", "prod": "production", "int": "integration"}.get(environment, environment)
        urls = {"staging": "https://api.stage.openshift.com", "production": "https://api.openshift.com",
                "integration": "https://api.integration.openshift.com"}
        if environment not in urls:
            raise ValueError("invalid_environment")
        token = os.environ.pop("OCM_TOKEN", "")
        if not token:
            raise ValueError("token_unavailable")
        _, status = command(["ocm", "login", "--url=" + urls[environment], "--token=" + token])
        del token
        if status != "ok":
            raise ValueError("login_" + status)
        cluster_id = identity()
        preinstall(cluster_id)
        guest(cluster_id, work)
        OUTCOME["collector"] = "complete"
except ValueError as error:
    OUTCOME["collector"] = "incomplete"
    OUTCOME["reason"] = str(error) if str(error).startswith(("missing_identity:", "identity_lookup_", "ocm_install_", "login_")) or str(error) in {
        "invalid_identity_file", "malformed_identity", "ambiguous_identity", "unscoped_identity",
        "ambiguous_or_missing_name", "malformed_name", "invalid_run_window", "ambiguous_or_missing_match",
        "invalid_identity_match", "unscoped_creation_time", "invalid_environment", "token_unavailable",
        "invalid_identity_handoff", "identity_mismatch", "unverified_name_identity",
        "invalid_tool_archive",
    } else "invalid_response"
except Exception:
    OUTCOME["collector"] = "incomplete"
    OUTCOME["reason"] = "collector_error"
finally:
    artifact("collection-outcome.json", OUTCOME)
PY
exit 0
