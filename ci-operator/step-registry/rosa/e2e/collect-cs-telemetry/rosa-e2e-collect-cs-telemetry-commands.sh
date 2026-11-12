#!/bin/bash
set -o nounset
set -o errexit
set -o pipefail

RHOBS_ENV="${RHOBS_ENV:-staging}"

case "$RHOBS_ENV" in
  staging)
    LOKI_BASE="https://us-east-1-0.rhobs.api.stage.openshift.com/api/logs/v1/hcp/loki/api/v1"
    CS_NAMESPACE="${CS_NAMESPACE:-uhc-stage}"
    ;;
  production)
    LOKI_BASE="https://us-east-1-0.rhobs.api.openshift.com/api/logs/v1/hcp/loki/api/v1"
    CS_NAMESPACE="${CS_NAMESPACE:-uhc-production}"
    ;;
  integration)
    LOKI_BASE="https://us-west-2-0.rhobs.api.integration.openshift.com/api/logs/v1/hcp/loki/api/v1"
    CS_NAMESPACE="${CS_NAMESPACE:-uhc-integration}"
    ;;
  *)
    echo "ERROR: RHOBS_ENV must be staging, production, or integration"
    exit 1
    ;;
esac

START_TIME=$(cat "${SHARED_DIR}/job-start-time" 2>/dev/null || echo "")
if [[ -z "$START_TIME" ]]; then
  echo "WARNING: No job-start-time found, using last 4 hours"
  START_TIME=$(($(date +%s) - 14400))
fi
END_TIME=$(date +%s)

CLIENT_ID=$(cat /usr/local/rhobs-oidc/client_id)
CLIENT_SECRET=$(cat /usr/local/rhobs-oidc/client_secret)
ISSUER_URL=$(cat /usr/local/rhobs-oidc/oidc_issuer_url 2>/dev/null || echo "https://sso.redhat.com/auth/realms/redhat-external/protocol/openid-connect/token")

echo "Collecting CS telemetry from $RHOBS_ENV RHOBS"
echo "  Namespace: $CS_NAMESPACE"
echo "  Window: $(date -d "@$START_TIME" '+%Y-%m-%d %H:%M:%S' 2>/dev/null || date -r "$START_TIME" '+%Y-%m-%d %H:%M:%S') -> $(date -d "@$END_TIME" '+%Y-%m-%d %H:%M:%S' 2>/dev/null || date -r "$END_TIME" '+%Y-%m-%d %H:%M:%S')"

# ---------------------------------------------------------------------------
# Classic identity-provider resync events.
#
# These are collected separately from the HCP lifecycle report above because
# they are handled differently: the Loki response is parsed and reduced to an
# allowlisted schema before anything is written, and the raw response is never
# placed in ARTIFACT_DIR. The cluster identifiers of the run are read only to
# select this job's events out of a shared stream and are dropped by the
# parser, so they do not appear in the artifact.
# ---------------------------------------------------------------------------

CLASSIC_REPORT="${ARTIFACT_DIR}/classic-idp-resync-events.json"
CLASSIC_WORK="$(mktemp -d)"
trap 'rm -rf "${CLASSIC_WORK}"' EXIT

# Collect the run's cluster identifiers using the same SHARED_DIR convention as
# rosa-e2e-gather-cluster-diagnostics. Used as a selector only.
CLASSIC_SELECTORS="${CLASSIC_WORK}/selectors"
: > "$CLASSIC_SELECTORS"
for candidate in "${SHARED_DIR}/cluster-id" "${SHARED_DIR}/ocm-fvt-cluster-ids"; do
  if [[ -s "$candidate" ]]; then
    grep -oE '[A-Za-z0-9]+' < "$candidate" >> "$CLASSIC_SELECTORS" || true
  fi
done
sort -u -o "$CLASSIC_SELECTORS" "$CLASSIC_SELECTORS"

classic_report_only() {
  python3 - "$CLASSIC_REPORT" "$1" "$START_TIME" "$END_TIME" <<'PYEOF'
import json, sys
from datetime import datetime, timezone
path, status, start_ts, end_ts = sys.argv[1], sys.argv[2], int(sys.argv[3]), int(sys.argv[4])
iso = lambda t: datetime.fromtimestamp(t, tz=timezone.utc).strftime("%Y-%m-%dT%H:%M:%SZ")
with open(path, "w") as handle:
    json.dump({"schema": "rosa.classic.idp.resync.report/v1",
               "window": {"start": iso(start_ts), "end": iso(end_ts)},
               "collection": {"status": status},
               "events": [], "rejected": {}, "anomalies": {}}, handle, indent=2)
PYEOF
  echo "  Classic IDP resync: ${1}, wrote ${CLASSIC_REPORT}"
}

TOKEN=$(curl -sf -X POST "$ISSUER_URL" \
    -d "grant_type=client_credentials" \
    -d "client_id=$CLIENT_ID" \
    -d "client_secret=$CLIENT_SECRET" | python3 -c "import sys,json; print(json.load(sys.stdin)['access_token'])" 2>/dev/null) || {
  echo "WARNING: Failed to get RHOBS token, skipping telemetry collection"
  classic_report_only "token_unavailable"
  exit 0
}

QUERY="{k8s_namespace_name=\"${CS_NAMESPACE}\"} |= \"[ROSA HCP -\""

RAW_FILE="${ARTIFACT_DIR}/cs-telemetry-raw.json"
HCP_QUERY_OK=true

if ! curl -sf --max-time 120 \
    -H "Authorization: Bearer $TOKEN" \
    --data-urlencode "query=$QUERY" \
    --data-urlencode "start=${START_TIME}000000000" \
    --data-urlencode "end=${END_TIME}000000000" \
    --data-urlencode "limit=5000" \
    --data-urlencode "direction=forward" \
    -G "$LOKI_BASE/query_range" \
    -o "$RAW_FILE" 2>/dev/null; then
  echo "WARNING: HCP telemetry query failed, continuing to Classic IDP collection"
  HCP_QUERY_OK=false
fi

if [[ "$HCP_QUERY_OK" == "true" ]]; then
python3 - "$RAW_FILE" "$CS_NAMESPACE" "$START_TIME" "$END_TIME" "$RHOBS_ENV" > "${ARTIFACT_DIR}/cs-telemetry.log" <<'PYEOF'
import sys, json, re
from datetime import datetime, timezone
from collections import defaultdict

with open(sys.argv[1], "r") as f:
    telemetry = json.load(f)
cs_ns = sys.argv[2]
start_ts = int(sys.argv[3])
end_ts = int(sys.argv[4])
env = sys.argv[5]

entries = []
for stream in telemetry.get("data", {}).get("result", []):
    for ts_ns, msg in stream.get("values", []):
        ts = int(ts_ns) / 1e9
        entries.append((ts, msg))
entries.sort(key=lambda x: x[0])

start_dt = datetime.fromtimestamp(start_ts, tz=timezone.utc).strftime("%Y-%m-%d %H:%M:%S UTC")
end_dt = datetime.fromtimestamp(end_ts, tz=timezone.utc).strftime("%Y-%m-%d %H:%M:%S UTC")

print("=" * 80)
print("Clusters Service Telemetry Report")
print("=" * 80)
print(f"Environment: {env} ({cs_ns})")
print(f"Time window: {start_dt} -> {end_dt}")
print(f"Total events: {len(entries)}")

clusters = defaultdict(list)
for ts, msg in entries:
    cid_m = re.search(r"\[cid='([^']+)'\]", msg)
    cid = cid_m.group(1) if cid_m else "unknown"
    clusters[cid].append((ts, msg))

print(f"Clusters seen: {len(clusters)}")
print()

for cid, events in sorted(clusters.items(), key=lambda x: x[1][0][0]):
    cluster_m = re.search(r"Cluster: '([^']*)'", events[0][1])
    cluster = cluster_m.group(1) if cluster_m else cid

    tags = []
    for _, msg in events:
        tag_m = re.search(r"\[ROSA HCP - (\w+\.?\d*)\]", msg)
        if tag_m:
            tags.append(tag_m.group(1))

    has_ready = "IT7" in tags
    has_deprov = any(t.startswith("UT") for t in tags)
    has_upgrade = any(t.startswith("UCT") or t.startswith("UNT") for t in tags)

    lifecycle = []
    if "IT1" in tags:
        lifecycle.append("INSTALL")
    if has_ready:
        lifecycle.append("READY")
    if has_upgrade:
        lifecycle.append("UPGRADE")
    if has_deprov:
        lifecycle.append("DEPROVISION")

    status = " -> ".join(lifecycle) if lifecycle else "IN PROGRESS"

    print("-" * 80)
    print(f"Cluster: {cluster}  (cid={cid})")
    print(f"Events: {len(events)}  Lifecycle: {status}")
    print()

    for ts, msg in events:
        dt = datetime.fromtimestamp(ts, tz=timezone.utc).strftime("%H:%M:%S")
        tag_m = re.search(r"\[ROSA HCP - (\w+\.?\d*)\]", msg)
        tag = tag_m.group(1) if tag_m else "?"

        detail = ""
        state_m = re.search(r"State: '([^']*)'", msg)
        op_m = re.search(r"Operation: '([^']*)'", msg)
        kind_m = re.search(r"Kind: '([^']*)'", msg)
        name_m = re.search(r"Name: '([^']*)'", msg)
        status_m = re.search(r"Status: '([^']*)'", msg)
        ver_m = re.search(r"Target Version: '([^']*)'", msg)
        detail_m = re.search(r" - (.+)$", msg)

        if state_m:
            detail = f"state={state_m.group(1)}"
        elif op_m and kind_m:
            detail = f"{op_m.group(1)} {kind_m.group(1)}"
            if name_m:
                n = name_m.group(1)
                if len(n) > 40:
                    n = n[:37] + "..."
                detail += f" {n}"
        elif detail_m and tag.startswith("UT"):
            detail = detail_m.group(1)

        if status_m and not detail.endswith(f"[{status_m.group(1)}]"):
            detail += f" [{status_m.group(1)}]"
        if ver_m:
            detail += f" target={ver_m.group(1)}"

        print(f"  {dt}  {tag:<10s}  {detail}")

    print()

if not entries:
    print()
    print("No CS telemetry events found in the given time window.")
    print("This is expected if no clusters were provisioned/deprovisioned during this job.")

print("=" * 80)
PYEOF

EVENT_COUNT=$(python3 -c "
import json
d=json.load(open('${ARTIFACT_DIR}/cs-telemetry-raw.json'))
print(sum(len(r.get('values',[])) for r in d.get('data',{}).get('result',[])))
" 2>/dev/null || echo "?")

echo "  Events collected: $EVENT_COUNT"
echo "  Output: ${ARTIFACT_DIR}/cs-telemetry.log"
fi

if [[ ! -s "$CLASSIC_SELECTORS" ]]; then
  # No identifier to select on. Reported explicitly: an empty event list without
  # this status would read as "the resync did not happen".
  classic_report_only "selector_unavailable"
else
  CLASSIC_QUERY="{k8s_namespace_name=\"${CS_NAMESPACE}\"} |= \"[ROSA CLASSIC IDP]\""
  if ! curl -sf --max-time 120 \
      -H "Authorization: Bearer $TOKEN" \
      --data-urlencode "query=$CLASSIC_QUERY" \
      --data-urlencode "start=${START_TIME}000000000" \
      --data-urlencode "end=${END_TIME}000000000" \
      --data-urlencode "limit=5000" \
      --data-urlencode "direction=forward" \
      -G "$LOKI_BASE/query_range" \
      -o "${CLASSIC_WORK}/raw.json" 2>/dev/null; then
    classic_report_only "query_failed"
  else
    if ! python3 - "${CLASSIC_WORK}/raw.json" "$CLASSIC_SELECTORS" "$CLASSIC_REPORT" \
        "$START_TIME" "$END_TIME" <<'PYEOF'
import json, sys
from datetime import datetime, timezone

raw_path, selector_path, out_path = sys.argv[1], sys.argv[2], sys.argv[3]
start_ts, end_ts = int(sys.argv[4]), int(sys.argv[5])

TAG = "[ROSA CLASSIC IDP]"
EVENT_SCHEMA = "rosa.classic.idp.resync/v1"
OPS = {"source_secret_write", "lease_delete", "sync_identity_provider_write", "syncset_write"}
OUTCOMES = {"succeeded", "deleted", "not_found", "forbidden", "conflict", "failed"}
# cluster_id is a selector, never output. Any other field is unexpected.
PAYLOAD_FIELDS = {"schema", "op", "outcome", "build", "time", "cluster_id", "generation",
                  "attempt"}
# Keys a log pipeline may wrap the service's message in.
ENVELOPE_KEYS = ("message", "msg", "log", "_line")

# rejected counts events that were dropped. A build whose shape is not recognised does not
# drop the event - only its build value is withheld - so it is counted separately.
rejected = {k: 0 for k in ("unparsable_envelope", "unwrap_failed", "undecodable_payload",
                           "unknown_schema", "unexpected_field", "unknown_op",
                           "unknown_outcome", "other_cluster", "invalid_time",
                           "out_of_window", "invalid_generation")}
anomalies = {"build_not_recorded": 0}

with open(selector_path) as handle:
    selectors = {line.strip() for line in handle if line.strip()}

def iso(epoch):
    return datetime.fromtimestamp(epoch, tz=timezone.utc).strftime("%Y-%m-%dT%H:%M:%SZ")

def unwrap(value):
    """Return the service's message, unwrapping a JSON log envelope if there is one."""
    text = value if isinstance(value, str) else ""
    stripped = text.lstrip()
    if not stripped.startswith("{"):
        return text
    try:
        envelope = json.loads(text)
    except (ValueError, TypeError):
        return text
    if not isinstance(envelope, dict):
        return text
    for key in ENVELOPE_KEYS:
        inner = envelope.get(key)
        if isinstance(inner, str):
            return inner
    return ""

def build_shape(build):
    """Classify a build string. A hexadecimal shape does not by itself prove the value is a
    git object name: an all-decimal value cannot be told apart from a git object name whose
    digits happen to all be decimal, nor from any other all-decimal version string a build
    may inject. That ambiguity is reported, not resolved."""
    if not isinstance(build, str) or not 7 <= len(build) <= 64:
        return None, "unrecognized"
    if not all(c in "0123456789abcdef" for c in build):
        return None, "unrecognized"
    if build.isdigit():
        return build, "ambiguous_numeric_or_git_object_name"
    return build, "git_object_name"

try:
    with open(raw_path) as handle:
        telemetry = json.load(handle)
except (ValueError, OSError):
    telemetry = {}
if not isinstance(telemetry, dict):
    telemetry = {}

events = []
data = telemetry.get("data")
streams = (data.get("result") if isinstance(data, dict) else None) or []
for stream in streams:
    if not isinstance(stream, dict):
        rejected["unwrap_failed"] += 1
        continue
    for entry in stream.get("values") or []:
        if not isinstance(entry, list) or len(entry) != 2:
            rejected["unparsable_envelope"] += 1
            continue
        message = unwrap(entry[1])
        marker = message.find(TAG)
        if marker < 0:
            rejected["unwrap_failed"] += 1
            continue
        # The service's log encoder appends its configured context fields after the message,
        # so the event is not necessarily the end of the line. Decode just the JSON value and
        # discard whatever follows it; the remainder is never read or written.
        try:
            payload, _ = json.JSONDecoder().raw_decode(message, marker + len(TAG) + 1)
        except ValueError:
            rejected["undecodable_payload"] += 1
            continue
        if not isinstance(payload, dict):
            rejected["undecodable_payload"] += 1
            continue
        if payload.get("schema") != EVENT_SCHEMA:
            rejected["unknown_schema"] += 1
            continue
        if set(payload) - PAYLOAD_FIELDS:
            # An unrecognised field may be anything at all, so the event is dropped whole
            # rather than filtered down to the fields this parser happens to know.
            rejected["unexpected_field"] += 1
            continue
        if payload.get("cluster_id") not in selectors:
            rejected["other_cluster"] += 1
            continue
        if payload.get("op") not in OPS:
            rejected["unknown_op"] += 1
            continue
        if payload.get("outcome") not in OUTCOMES:
            rejected["unknown_outcome"] += 1
            continue
        stamp = payload.get("time")
        try:
            moment = datetime.strptime(stamp, "%Y-%m-%dT%H:%M:%SZ").replace(tzinfo=timezone.utc)
        except (ValueError, TypeError):
            rejected["invalid_time"] += 1
            continue
        if not start_ts <= moment.timestamp() <= end_ts:
            rejected["out_of_window"] += 1
            continue
        generation = payload.get("generation")
        if generation is not None and (not isinstance(generation, int)
                                       or isinstance(generation, bool) or generation < 0):
            rejected["invalid_generation"] += 1
            continue
        build, shape = build_shape(payload.get("build"))
        if shape == "unrecognized":
            anomalies["build_not_recorded"] += 1
        attempt = payload.get("attempt")
        if not isinstance(attempt, int) or isinstance(attempt, bool) or attempt < 1:
            rejected["invalid_generation"] += 1
            continue
        reduced = {"op": payload["op"], "outcome": payload["outcome"],
                   "time": moment.strftime("%Y-%m-%dT%H:%M:%SZ"), "attempt": attempt,
                   "build_shape": shape}
        if build is not None:
            reduced["build"] = build
        if generation is not None:
            reduced["generation"] = generation
        events.append(reduced)

events.sort(key=lambda e: (e["time"], e["attempt"]))
status = "collected" if events else "no_events_in_window"
with open(out_path, "w") as handle:
    json.dump({"schema": "rosa.classic.idp.resync.report/v1",
               "window": {"start": iso(start_ts), "end": iso(end_ts)},
               "collection": {"status": status},
               "events": events, "rejected": rejected, "anomalies": anomalies},
              handle, indent=2)
print(f"  Classic IDP resync: {status}, {len(events)} event(s), "
      f"{sum(rejected.values())} rejected")
PYEOF
    then
      classic_report_only "parse_failed"
    fi
  fi
fi
echo "  Output: ${CLASSIC_REPORT}"
