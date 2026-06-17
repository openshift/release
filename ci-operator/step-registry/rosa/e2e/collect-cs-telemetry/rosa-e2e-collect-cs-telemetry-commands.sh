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

TOKEN=$(curl -sf -X POST "$ISSUER_URL" \
    -d "grant_type=client_credentials" \
    -d "client_id=$CLIENT_ID" \
    -d "client_secret=$CLIENT_SECRET" | python3 -c "import sys,json; print(json.load(sys.stdin)['access_token'])" 2>/dev/null) || {
  echo "WARNING: Failed to get RHOBS token, skipping telemetry collection"
  exit 0
}

QUERY="{k8s_namespace_name=\"${CS_NAMESPACE}\"} |= \"[ROSA HCP -\""

TELEMETRY=$(curl -sf --max-time 120 \
    -H "Authorization: Bearer $TOKEN" \
    --data-urlencode "query=$QUERY" \
    --data-urlencode "start=${START_TIME}000000000" \
    --data-urlencode "end=${END_TIME}000000000" \
    --data-urlencode "limit=5000" \
    --data-urlencode "direction=forward" \
    -G "$LOKI_BASE/query_range" 2>/dev/null) || {
  echo "WARNING: Telemetry query failed, skipping"
  exit 0
}

python3 - "$TELEMETRY" "$CS_NAMESPACE" "$START_TIME" "$END_TIME" "$RHOBS_ENV" > "${ARTIFACT_DIR}/cs-telemetry.log" <<'PYEOF'
import sys, json, re
from datetime import datetime, timezone
from collections import defaultdict

telemetry = json.loads(sys.argv[1])
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

echo "$TELEMETRY" > "${ARTIFACT_DIR}/cs-telemetry-raw.json"

EVENT_COUNT=$(python3 -c "
import json
d=json.loads(open('${ARTIFACT_DIR}/cs-telemetry-raw.json').read())
print(sum(len(r.get('values',[])) for r in d.get('data',{}).get('result',[])))
" 2>/dev/null || echo "?")

echo "  Events collected: $EVENT_COUNT"
echo "  Output: ${ARTIFACT_DIR}/cs-telemetry.log"
