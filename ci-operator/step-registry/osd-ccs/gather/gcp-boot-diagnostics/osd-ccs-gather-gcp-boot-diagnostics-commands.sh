#!/bin/bash
set -o nounset
set -o pipefail
# Deliberately no errexit: this step must always exit 0 so that the cluster
# deprovision steps that follow it in the post phase always run.

OUTPUT_DIR="${ARTIFACT_DIR}/gcp-boot-diagnostics"
mkdir -p "${OUTPUT_DIR}"

# Never interpolate collected data into this message.
log() {
  echo "[gcp-boot-diagnostics] $*"
}

# ---- opt-in gate -------------------------------------------------------------
#
# Evaluated before anything else. While disabled this step reads no credential
# file, performs no cloud authentication and issues no cloud API call.

if [[ "${OSD_CCS_GATHER_GCP_BOOT_DIAGNOSTICS:-false}" != "true" ]]; then
  printf '{"schema":1,"collector":"disabled","reason":"opt_in_required"}\n' \
    > "${OUTPUT_DIR}/collection-outcome.json"
  log "disabled by default; no credential read and no cloud access performed."
  exit 0
fi

# The collector is written in Python. Report its absence as a fixed outcome
# rather than leaving the provisional document behind with a misleading reason.
if ! command -v python3 >/dev/null 2>&1; then
  printf '{"schema":1,"collector":"incomplete","reason":"tooling_unavailable"}\n' \
    > "${OUTPUT_DIR}/collection-outcome.json"
  log "python3 is not available in this image; nothing collected."
  exit 0
fi

# ---- scratch state -----------------------------------------------------------
#
# Serial output is hostile input. It is only ever written to this private
# scratch directory, which lives outside ARTIFACT_DIR and SHARED_DIR and is
# removed on normal exit and on signals.

umask 0077

# The scratch directory must never live under a directory that is published or
# handed to another step, whatever TMPDIR happens to say. Comparing the strings
# is not enough: a symlinked or relative TMPDIR can resolve into one of them.
# Canonicalise every path first, and decide before anything is created.
canonicalise() {
  realpath -m -- "$1" 2>/dev/null || readlink -m -- "$1" 2>/dev/null || true
}

SCRATCH_BASE="$(canonicalise "${TMPDIR:-/tmp}")"
ARTIFACT_CANON="$(canonicalise "${ARTIFACT_DIR}")"
SHARED_CANON="$(canonicalise "${SHARED_DIR:-}")"

if [[ -z "${SCRATCH_BASE}" || -z "${ARTIFACT_CANON}" ]]; then
  # Without canonical paths the candidate cannot be shown to be safe.
  SCRATCH_BASE="/tmp"
else
  case "${SCRATCH_BASE}/" in
    "${ARTIFACT_CANON}"/*) SCRATCH_BASE="/tmp" ;;
  esac
  if [[ -n "${SHARED_CANON}" ]]; then
    case "${SCRATCH_BASE}/" in
      "${SHARED_CANON}"/*) SCRATCH_BASE="/tmp" ;;
    esac
  fi
fi

SCRATCH="$(mktemp -d "${SCRATCH_BASE}/gcp-boot-diag.XXXXXX" 2>/dev/null)" || SCRATCH=""
if [[ -z "${SCRATCH}" || ! -d "${SCRATCH}" ]]; then
  printf '{"schema":1,"collector":"incomplete","reason":"scratch_unavailable"}\n' \
    > "${OUTPUT_DIR}/collection-outcome.json"
  log "unable to create private scratch directory; nothing collected."
  exit 0
fi

# Re-check the directory that actually got created, so the invariant holds even
# if the base was changed underneath us.
SCRATCH_CANON="$(canonicalise "${SCRATCH}")"
if [[ -z "${SCRATCH_CANON}" ]] || { [[ -n "${ARTIFACT_CANON}" ]] && [[ "${SCRATCH_CANON}/" == "${ARTIFACT_CANON}"/* ]]; } \
   || { [[ -n "${SHARED_CANON}" ]] && [[ "${SCRATCH_CANON}/" == "${SHARED_CANON}"/* ]]; }; then
  rm -rf "${SCRATCH}" 2>/dev/null || true
  printf '{"schema":1,"collector":"incomplete","reason":"scratch_unavailable"}\n' \
    > "${OUTPUT_DIR}/collection-outcome.json"
  log "refusing to stage collected data under a published directory."
  exit 0
fi
chmod 0700 "${SCRATCH}"

# Publish a provisional outcome immediately, so that the document still exists
# and still says something true if this step is killed before it finishes.
printf '{"schema":1,"collector":"incomplete","reason":"interrupted"}\n' \
  > "${OUTPUT_DIR}/collection-outcome.json"

COLLECTOR_PID=""

# shellcheck disable=SC2317  # invoked via trap
cleanup() {
  if [[ -n "${COLLECTOR_PID}" ]]; then
    kill "${COLLECTOR_PID}" 2>/dev/null || true
    wait "${COLLECTOR_PID}" 2>/dev/null || true
  fi
  rm -rf "${SCRATCH}" 2>/dev/null || true
}
trap cleanup EXIT
trap 'cleanup; exit 0' HUP INT TERM

# Keep gcloud fully non-interactive and confined to the scratch directory.
export CLOUDSDK_CONFIG="${SCRATCH}/gcloud"
export CLOUDSDK_CORE_DISABLE_PROMPTS=1

# Run the collector in the background and wait for it, so that a signal is
# handled while it is still running instead of after it returns.
python3 - "${SCRATCH}" "${OUTPUT_DIR}" <<'PYTHON' &
"""Collect bounded, allow-listed boot signals from this run's GCP instances.

Published output is drawn from a fixed vocabulary defined in this file. No
serial-console text, command output, instance name, zone or project identifier
is ever written to ARTIFACT_DIR or printed.
"""

import json
import os
import re
import subprocess
import sys
import time
from pathlib import Path

SCRATCH = Path(sys.argv[1])
OUTPUT_DIR = Path(sys.argv[2])


def positive(name, default, limit):
    try:
        value = int(os.environ.get(name, "") or default)
    except ValueError:
        return default
    return default if value <= 0 or value > limit else value


BUDGET_SECONDS = positive("OSD_CCS_GATHER_GCP_BOOT_BUDGET_SECONDS", 240, 540)
CALL_SECONDS = positive("OSD_CCS_GATHER_GCP_BOOT_CALL_TIMEOUT_SECONDS", 45, 120)
MAX_INSTANCES = positive("OSD_CCS_GATHER_GCP_BOOT_MAX_INSTANCES", 8, 32)
MAX_OUTPUT_BYTES = 4 * 1024 * 1024
MAX_LINES = 60000
MAX_LINE_CHARS = 4096
CHUNK_CHARS = 65536
DEADLINE_CHECK_EVERY = 512

DEADLINE = time.monotonic() + BUDGET_SECONDS

# Identifier shapes we are willing to act on. Anything else fails closed.
CLUSTER_NAME = re.compile(r"\A[a-z][a-z0-9-]{1,29}\Z")
INSTANCE = re.compile(r"\A[a-z][a-z0-9-]{0,61}[a-z0-9]\Z")
ZONE = re.compile(r"\A[a-z]{2,20}-[a-z]{2,20}[0-9]{1,2}-[a-z]\Z")
PROJECT = re.compile(r"\A[a-z][a-z0-9-]{4,28}[a-z0-9]\Z")

# Units whose boot signals we are willing to report, and nothing else.
UNITS = (
    "ignition-fetch.service",
    "ignition-fetch-offline.service",
    "ignition-disks.service",
    "ignition-mount.service",
    "ignition-files.service",
    "ignition-firstboot-complete.service",
    "afterburn-firstboot-checkin.service",
    "afterburn-hostname.service",
    "NetworkManager.service",
    "nodeip-configuration.service",
    "machine-config-daemon-firstboot.service",
    "machine-config-daemon-pull.service",
    "crio.service",
    "kubelet.service",
)

FAILURE_PATTERNS = (
    "failed to start",
    "failed with result",
    "main process exited",
    "entered failed state",
    "start request repeated too quickly",
)

# Each marker is a tuple of alternatives; an alternative matches when all of its
# substrings appear in the lower-cased line. Plain substring tests are used
# instead of regular expressions so that matching stays linear in line length
# and a hostile line cannot drive catastrophic backtracking.
MARKERS = {
    "ignition_finished": (("ignition finished successfully",),),
    "ignition_failure": (("ignition failed",), ("ignition has failed",)),
    "multi_user_target": (("reached target", "multi-user"),),
    "network_online_target": (("reached target", "network is online"),),
    "kernel_panic": (("kernel panic",),),
    "out_of_memory": (("out of memory: killed process",),),
    "emergency_shell": (("emergency mode",), ("emergency shell",),
                        ("rescue mode",), ("rescue shell",)),
}

# Fixed classification of a failed cloud call. Derived from, never containing,
# the command's stderr.
ERROR_CLASSES = (
    ("permission_denied", ("permission denied", "permission_denied", "403",
                           "forbidden", "does not have", "required 'compute")),
    ("not_found", ("not found", "404", "was not found")),
    ("unauthenticated", ("401", "unauthenticated", "invalid_grant",
                         "could not determine the current account")),
    ("quota_exceeded", ("quota", "rate limit", "429")),
)

OUTCOME = {
    "schema": 1,
    "collector": "incomplete",
    "reason": "not_started",
    "instances_discovered": 0,
    "instances_examined": 0,
    "instances": [],
    "limits": {
        "budget_seconds": BUDGET_SECONDS,
        "call_timeout_seconds": CALL_SECONDS,
        "max_instances": MAX_INSTANCES,
        "max_output_bytes": MAX_OUTPUT_BYTES,
    },
    "disclaimer": (
        "Unit values are signals observed in serial-console output, not "
        "authoritative current systemd state. no_signal means not observed, "
        "never healthy. These observations do not establish a root cause."
    ),
}


class Failure(Exception):
    """Carries a fixed, allow-listed outcome reason."""


def publish():
    path = OUTPUT_DIR / "collection-outcome.json"
    path.write_text(json.dumps(OUTCOME, indent=2, sort_keys=True) + "\n",
                    encoding="utf-8")
    path.chmod(0o644)


def classify(text):
    lowered = (text or "").lower()
    for name, needles in ERROR_CLASSES:
        if any(needle in lowered for needle in needles):
            return name
    return "error"


def remaining():
    left = DEADLINE - time.monotonic()
    if left <= 1:
        raise Failure("budget_exhausted")
    return min(CALL_SECONDS, left)


def gcloud(arguments, sink):
    """Run a read-only gcloud call. stdout goes to a scratch file, never to us."""
    timeout = remaining()
    with sink.open("wb") as stdout:
        try:
            completed = subprocess.run(
                ["gcloud", *arguments], stdout=stdout, stderr=subprocess.PIPE,
                timeout=timeout, check=False)
        except subprocess.TimeoutExpired:
            return "timeout"
        except (OSError, ValueError):
            return "unavailable"
    sink.chmod(0o600)
    if completed.returncode != 0:
        try:
            detail = completed.stderr.decode("utf-8", "replace")
        except Exception:  # pragma: no cover - decode is already lenient
            detail = ""
        return classify(detail)
    return "ok"


def identity():
    """Resolve this run's cluster name. Fails closed; never scans the project."""
    shared = os.environ.get("SHARED_DIR", "")
    if not shared:
        raise Failure("identity_unavailable")
    path = Path(shared) / "cluster-name"
    if path.is_symlink() or not path.is_file():
        raise Failure("identity_unavailable")
    try:
        raw = path.read_text(encoding="utf-8")
    except OSError:
        raise Failure("identity_unavailable")
    names = [line.strip() for line in raw.splitlines() if line.strip()]
    if len(names) != 1:
        raise Failure("identity_ambiguous")
    if not CLUSTER_NAME.match(names[0]):
        raise Failure("identity_malformed")
    return names[0]


def project():
    """Read the project id from the profile credential already used by this workflow."""
    profile = os.environ.get("CLUSTER_PROFILE_DIR", "")
    if not profile:
        raise Failure("credential_unavailable")
    path = Path(profile) / "osd-ccs-gcp.json"
    if path.is_symlink() or not path.is_file():
        raise Failure("credential_unavailable")
    try:
        document = json.loads(path.read_text(encoding="utf-8"))
        value = document["project_id"]
    except (OSError, ValueError, KeyError, TypeError):
        raise Failure("credential_malformed")
    if not isinstance(value, str) or not PROJECT.match(value):
        raise Failure("credential_malformed")
    status = gcloud(["auth", "activate-service-account", "--key-file=" + str(path)],
                    SCRATCH / "auth.out")
    if status != "ok":
        raise Failure("auth_" + status)
    return value


def discover(cluster, project_id):
    """List only instances belonging to this run. No broad project discovery."""
    sink = SCRATCH / "instances.json"
    status = gcloud([
        "compute", "instances", "list",
        "--project", project_id,
        "--filter", "name:{0}-*".format(cluster),
        "--format", "json(name,zone,status)",
    ], sink)
    if status != "ok":
        raise Failure("discovery_" + status)
    try:
        listed = json.loads(sink.read_text(encoding="utf-8"))
    except (OSError, ValueError):
        raise Failure("discovery_invalid_response")
    if not isinstance(listed, list):
        raise Failure("discovery_invalid_response")

    prefix = cluster + "-"
    scoped = []
    rejected = 0
    for entry in listed[: MAX_INSTANCES * 4]:
        if not isinstance(entry, dict):
            rejected += 1
            continue
        name = entry.get("name")
        zone = entry.get("zone") or ""
        # A server-side filter is not a trust boundary: re-verify that every
        # instance really belongs to this run before touching it.
        if not isinstance(name, str) or not name.startswith(prefix):
            rejected += 1
            continue
        if not INSTANCE.match(name):
            rejected += 1
            continue
        zone = zone.rsplit("/", 1)[-1] if isinstance(zone, str) else ""
        if not ZONE.match(zone):
            rejected += 1
            continue
        scoped.append((name, zone, entry.get("status")))
    OUTCOME["instances_rejected_out_of_scope"] = rejected
    OUTCOME["instances_discovered"] = len(scoped)
    if rejected and not scoped:
        raise Failure("discovery_out_of_scope")
    return scoped[:MAX_INSTANCES]


def bounded_lines(handle, meter):
    """Yield length-capped lines, reading at most MAX_OUTPUT_BYTES.

    Serial output may legitimately contain no newline at all, so lines are
    assembled from fixed-size chunks rather than by iterating the file. The
    remainder of a line longer than MAX_LINE_CHARS is discarded. The amount
    consumed is recorded in meter so that the bound is observable.
    """
    consumed = 0
    pending = ""
    skipping = False
    while consumed < MAX_OUTPUT_BYTES:
        chunk = handle.read(min(CHUNK_CHARS, MAX_OUTPUT_BYTES - consumed))
        if not chunk:
            break
        consumed += len(chunk)
        meter[0] = consumed
        pending += chunk
        while True:
            index = pending.find("\n")
            if index < 0:
                break
            line, pending = pending[:index], pending[index + 1:]
            if skipping:
                skipping = False
                continue
            # The cap applies whether or not the line happened to be
            # newline-terminated; content past it is never scanned.
            yield line[:MAX_LINE_CHARS]
        if len(pending) > MAX_LINE_CHARS:
            if not skipping:
                yield pending[:MAX_LINE_CHARS]
            pending = ""
            skipping = True
    if pending and not skipping:
        yield pending[:MAX_LINE_CHARS]


def summarize(path, oversized):
    """Reduce serial output to counts and fixed enums. Returns no input text."""
    units = {unit: {"status": "no_signal", "events": 0} for unit in UNITS}
    markers = {name: 0 for name in MARKERS}
    lines = 0
    truncated = oversized
    meter = [0]
    try:
        with path.open("r", encoding="utf-8", errors="replace") as handle:
            for line in bounded_lines(handle, meter):
                lines += 1
                if lines > MAX_LINES:
                    truncated = True
                    break
                # Parsing happens inside the step's overall budget too.
                if lines % DEADLINE_CHECK_EVERY == 0 and time.monotonic() >= DEADLINE:
                    truncated = True
                    break
                lowered = line.lower()
                for name, alternatives in MARKERS.items():
                    if any(all(needle in lowered for needle in alternative)
                           for alternative in alternatives):
                        markers[name] += 1
                for unit in UNITS:
                    if unit.lower() not in lowered:
                        continue
                    record = units[unit]
                    record["events"] += 1
                    if any(needle in lowered for needle in FAILURE_PATTERNS):
                        record["status"] = "failed_signal_observed"
                    elif record["status"] in ("no_signal", "start_attempt_observed"):
                        if "started " in lowered:
                            record["status"] = "started_signal_observed"
                        elif "starting " in lowered:
                            record["status"] = "start_attempt_observed"
    except OSError:
        return {"parse": "unreadable"}
    return {
        "parse": "ok",
        "lines_scanned": min(lines, MAX_LINES),
        "lines_truncated": truncated,
        "characters_scanned": meter[0],
        "markers": markers,
        "units": units,
    }


def collect(instances, project_id):
    """Read each in-scope instance.

    A Failure raised here means the overall budget ran out before every
    instance was attempted. It propagates, so the sweep is not reported as
    complete, while the records gathered so far are kept. An ordinary
    per-instance timeout is a status on that instance and does not propagate.
    """
    examined = 0
    try:
        for index, (name, zone, state) in enumerate(instances):
            sink = SCRATCH / "serial-{0}.log".format(index)
            status = gcloud([
                "compute", "instances", "get-serial-port-output",
                "--project", project_id, "--zone", zone, name,
            ], sink)
            # The read was attempted and came back with a status, whatever it
            # says. Count it here, before any parsing, so that a denied, timed
            # out or unparseable read is still counted as examined and the
            # count can never fall behind the records below.
            examined += 1
            # Instance names, zones and project ids are deliberately absent here.
            record = {
                "index": index,
                "collection": status,
                "instance_state": state if state in (
                    "PROVISIONING", "STAGING", "RUNNING", "STOPPING",
                    "TERMINATED", "SUSPENDED", "REPAIRING") else "unknown",
            }
            if status == "ok":
                try:
                    size = sink.stat().st_size
                except OSError:
                    size = 0
                oversized = size > MAX_OUTPUT_BYTES
                record["bytes_truncated"] = oversized
                if size == 0:
                    record["collection"] = "no_signal"
                else:
                    record["signals"] = summarize(sink, oversized)
            try:
                sink.unlink()
            except OSError:
                pass
            OUTCOME["instances"].append(record)
    finally:
        OUTCOME["instances_examined"] = examined


try:
    cluster = identity()
    project_id = project()
    instances = discover(cluster, project_id)
    if not instances:
        OUTCOME["collector"] = "complete"
        OUTCOME["reason"] = "no_instances_in_scope"
    else:
        collect(instances, project_id)
        OUTCOME["collector"] = "complete"
        OUTCOME["reason"] = "collected"
except Failure as error:
    OUTCOME["reason"] = str(error)
except Exception:
    # Never let an unexpected error surface collected data in a traceback.
    OUTCOME["reason"] = "collector_error"
finally:
    try:
        publish()
    except OSError:
        pass
PYTHON
COLLECTOR_PID=$!
wait "${COLLECTOR_PID}" || true
COLLECTOR_PID=""

log "collection finished; see gcp-boot-diagnostics/collection-outcome.json"
exit 0
