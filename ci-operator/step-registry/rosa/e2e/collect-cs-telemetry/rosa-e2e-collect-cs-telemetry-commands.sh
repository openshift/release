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

# The credentials mount declared in rosa-e2e-collect-cs-telemetry-ref.yaml.
# hack/classic-idp-telemetry/classic_idp_step_test.py relocates this path to run the script
# without one; keep the three readers below spelling it the same way.
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
# The scratch directory holds the raw query response and the run's cluster identifiers, so it
# must never be under ARTIFACT_DIR. Without one there is nowhere safe to put them and Classic
# collection is skipped rather than degraded.
CLASSIC_WORK="$(mktemp -d)" || CLASSIC_WORK=""
# The explicit success keeps the EXIT trap from turning "there was no scratch to remove"
# into a non-zero exit status for the whole step.
classic_cleanup() {
  [[ -n "${CLASSIC_WORK}" ]] && rm -rf "${CLASSIC_WORK}"
  return 0
}
trap classic_cleanup EXIT INT TERM

# Collect the run's cluster identifiers using the same SHARED_DIR convention as
# rosa-e2e-gather-cluster-diagnostics. Used as a selector only.
CLASSIC_SKIP=false
if [[ -z "$CLASSIC_WORK" ]]; then
  echo "WARNING: no scratch directory; skipping Classic IDP collection"
  CLASSIC_SKIP=true
fi

# Bounded sanitized phase windows written by the test step, if it ran. Each line is an enum
# and two timestamps, which is what lets an event be attributed to the import under test
# rather than to any other write in the same job. Absent is reported, never guessed. The
# stand-in for an absent handoff lives in scratch: with no scratch there is nowhere to put
# one, and a root-level path would turn a missing handoff into a failed step.
CLASSIC_PHASES="${SHARED_DIR}/classic-idp-phase-windows"
# At most this many cluster ids are queried: each one costs a query inside the step's timeout.
CLASSIC_SELECTOR_CAP=8
CLASSIC_SELECTORS=""
# complete, truncated, or unknown when the selectors were never gathered. Reported either
# way: "no cluster id was excluded" and "we never looked" are different statements.
CLASSIC_SELECTOR_COVERAGE=unknown
# Everything below needs scratch to hold the selectors and the raw responses, so it is all
# skipped together rather than half-done.
if [[ "$CLASSIC_SKIP" != "true" ]]; then
  CLASSIC_SELECTORS="${CLASSIC_WORK}/selectors"
  : > "$CLASSIC_SELECTORS"
  if [[ ! -s "$CLASSIC_PHASES" ]]; then
    CLASSIC_PHASES="${CLASSIC_WORK}/no-phases"
    : > "$CLASSIC_PHASES"
  fi
  for candidate in "${SHARED_DIR}/cluster-id" "${SHARED_DIR}/ocm-fvt-cluster-ids"; do
    if [[ -s "$candidate" ]]; then
      # Only values shaped like a cluster id.
      grep -oE '[a-z0-9]{20,40}' < "$candidate" >> "$CLASSIC_SELECTORS" || true
    fi
  done
  LC_ALL=C sort -u "$CLASSIC_SELECTORS" > "${CLASSIC_WORK}/selectors.unique" || true
  # An id the cap excludes is still an id that may have emitted events, so a report that
  # dropped one must not read as "no resync ran": the exclusion is published. The fallback
  # keeps a scratch write that failed from ending the step here, with no report at all.
  CLASSIC_SELECTORS_SEEN=$(wc -l < "${CLASSIC_WORK}/selectors.unique" 2>/dev/null || echo 0)
  CLASSIC_SELECTOR_COVERAGE=complete
  if (( CLASSIC_SELECTORS_SEEN > CLASSIC_SELECTOR_CAP )); then
    CLASSIC_SELECTOR_COVERAGE=truncated
    echo "WARNING: ${CLASSIC_SELECTORS_SEEN} cluster id(s) found, querying the first ${CLASSIC_SELECTOR_CAP}"
  fi
  head -n "${CLASSIC_SELECTOR_CAP}" "${CLASSIC_WORK}/selectors.unique" > "$CLASSIC_SELECTORS" || true
  rm -f "${CLASSIC_WORK}/selectors.unique"
fi

# A report written without a query having been parsed. It still carries the coverage
# fields, so a consumer reads the same keys whatever the status.
classic_report_only() {
  python3 - "$CLASSIC_REPORT" "$1" "$START_TIME" "$END_TIME" "$CLASSIC_SELECTOR_COVERAGE" <<'PYEOF'
import json, sys
from datetime import datetime, timezone
path, status, start_ts, end_ts = sys.argv[1], sys.argv[2], int(sys.argv[3]), int(sys.argv[4])
coverage = sys.argv[5]
iso = lambda t: datetime.fromtimestamp(t, tz=timezone.utc).strftime("%Y-%m-%dT%H:%M:%SZ")
with open(path, "w") as handle:
    json.dump({"schema": "rosa.classic.idp.resync.report/v1",
               "window": {"start": iso(start_ts), "end": iso(end_ts)},
               # Nothing was parsed, so the handoff was never read and the result set
               # never existed: unknown, not a claim that either was absent.
               "collection": {"status": status,
                              "phase_windows": "unknown",
                              "selector_coverage": coverage,
                              "result_coverage": "unknown"},
               "events": [], "rejected": {}, "anomalies": {}}, handle, indent=2)
PYEOF
  echo "  Classic IDP resync: ${1}, wrote ${CLASSIC_REPORT}"
}

# The step is given 10m. One HCP query plus up to CLASSIC_SELECTOR_CAP Classic queries of
# QUERY_TIMEOUT each can exceed that, and a step killed on its timeout writes no report at
# all - which the documented contract says must never be mistaken for "no resync ran". So
# bound the whole query phase, leaving the remainder of the step for parsing and writing.
QUERY_TIMEOUT=120
QUERY_BUDGET=480
# Below this there is no point starting a query: it would be reported as a failure that
# says nothing about the backend. Report the budget instead.
QUERY_MINIMUM=15
QUERY_DEADLINE=$(( $(date +%s) + QUERY_BUDGET ))
# Seconds a query may take: what is left of the budget, capped at the per-query timeout.
# Fails when too little is left to be worth starting one.
query_seconds() {
  local remaining=$(( QUERY_DEADLINE - $(date +%s) ))
  (( remaining >= QUERY_MINIMUM )) || return 1
  (( remaining < QUERY_TIMEOUT )) && { echo "$remaining"; return 0; }
  echo "$QUERY_TIMEOUT"
}

TOKEN=$(curl -sf --max-time 60 -X POST "$ISSUER_URL" \
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
HCP_PARSE_OK=true

if ! HCP_MAX_TIME="$(query_seconds)"; then
  echo "WARNING: query budget exhausted before the HCP query, skipping it"
  HCP_QUERY_OK=false
  HCP_MAX_TIME=0
fi

if [[ "$HCP_QUERY_OK" == "true" ]] && ! curl -sf --max-time "$HCP_MAX_TIME" \
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

# A 200 with a body this parser cannot read makes it exit non-zero. Under errexit that would
# end the step here, before any Classic query or report - the same way a failed HCP query used
# to. Handle it like one: record it and carry on to the Classic path.
if [[ "$HCP_QUERY_OK" == "true" ]]; then
if ! python3 - "$RAW_FILE" "$CS_NAMESPACE" "$START_TIME" "$END_TIME" "$RHOBS_ENV" > "${ARTIFACT_DIR}/cs-telemetry.log" <<'PYEOF'
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
then
  echo "WARNING: HCP telemetry parse failed, continuing to Classic IDP collection"
  HCP_PARSE_OK=false
  # The log file holds whatever the parser managed to print before it stopped. Say so in
  # the artifact itself: a reader of the file alone would otherwise take it for complete.
  echo "ERROR: this report is incomplete - the parser failed partway through" \
    >> "${ARTIFACT_DIR}/cs-telemetry.log"
fi
fi

if [[ "$HCP_QUERY_OK" == "true" && "$HCP_PARSE_OK" == "true" ]]; then
  EVENT_COUNT=$(python3 -c "
import json
d=json.load(open('${ARTIFACT_DIR}/cs-telemetry-raw.json'))
print(sum(len(r.get('values',[])) for r in d.get('data',{}).get('result',[])))
" 2>/dev/null || echo "?")

  echo "  Events collected: $EVENT_COUNT"
  echo "  Output: ${ARTIFACT_DIR}/cs-telemetry.log"
fi

if [[ "$CLASSIC_SKIP" == "true" ]]; then
  # The report needs no scratch, only ARTIFACT_DIR, so the explicit-status contract still
  # holds here: a consumer must be able to tell this apart from the step never having run.
  classic_report_only "scratch_unavailable"
elif [[ ! -s "$CLASSIC_SELECTORS" ]]; then
  # No identifier to select on. Reported explicitly: an empty event list without
  # this status would read as "the resync did not happen".
  classic_report_only "selector_unavailable"
else
  # One query per selector, with the cluster id as a line filter, so the result set is this
  # run's events rather than every Classic event in a shared namespace. Without it a busy
  # window fills the limit with other runs' lines and this run's events fall outside it.
  CLASSIC_LIMIT=5000
  CLASSIC_QUERY_OK=true
  CLASSIC_TRUNCATED=false
  : > "${CLASSIC_WORK}/merged.json"
  while IFS= read -r selector; do
    [[ -n "$selector" ]] || continue
    CLASSIC_QUERY="{k8s_namespace_name=\"${CS_NAMESPACE}\"} |= \"[ROSA CLASSIC IDP]\" |= \"[cid='${selector}']\""
    if ! CLASSIC_MAX_TIME="$(query_seconds)"; then
      # Out of budget. Skipping is what lets the report still be written: a step killed on
      # its timeout writes nothing at all.
      echo "WARNING: query budget exhausted, skipping remaining Classic selector(s)"
      CLASSIC_QUERY_OK=false
      break
    fi
    if ! curl -sf --max-time "$CLASSIC_MAX_TIME" \
        -H "Authorization: Bearer $TOKEN" \
        --data-urlencode "query=$CLASSIC_QUERY" \
        --data-urlencode "start=${START_TIME}000000000" \
        --data-urlencode "end=${END_TIME}000000000" \
        --data-urlencode "limit=${CLASSIC_LIMIT}" \
        --data-urlencode "direction=forward" \
        -G "$LOKI_BASE/query_range" \
        -o "${CLASSIC_WORK}/sel.json" 2>/dev/null; then
      CLASSIC_QUERY_OK=false
      continue
    fi
    if [[ ! -s "${CLASSIC_WORK}/sel.json" ]]; then
      # curl is satisfied by a 204, or by a 200 a proxy emptied. The parser would see no
      # document at all and have nothing to count, so an empty body would read as "no
      # events" rather than as the answer that never arrived. Treat it as a failed query.
      echo "WARNING: empty Classic query response, treating as a failed query"
      CLASSIC_QUERY_OK=false
      continue
    fi
    # -s above tests size, not content. A body of blank space decodes to no document at
    # all, so nothing would be counted and the report would read "no events" for an answer
    # that never arrived; a body carrying two documents would be numbered as two cluster
    # groups although one selector produced it. Require exactly one JSON value, with only
    # whitespace after it, before this response joins the merged file. A valid document
    # whose result is empty is untouched and still reports a clean empty collection.
    if ! python3 -c '
import json, sys
with open(sys.argv[1]) as handle:
    text = handle.read()
start = len(text) - len(text.lstrip())
try:
    _, index = json.JSONDecoder().raw_decode(text, start)
except ValueError:
    sys.exit(1)
sys.exit(0 if text[index:].strip() == "" else 1)
' "${CLASSIC_WORK}/sel.json" 2>/dev/null; then
      echo "WARNING: Classic query response is not exactly one JSON document, treating as a failed query"
      CLASSIC_QUERY_OK=false
      continue
    fi
    cat "${CLASSIC_WORK}/sel.json" >> "${CLASSIC_WORK}/merged.json"
    printf '\n' >> "${CLASSIC_WORK}/merged.json"
    # A result set that exactly fills the limit may have been cut short; say so rather than
    # presenting a possibly partial list as the whole of it.
    CLASSIC_SEEN="$(python3 -c "
import json,sys
try:
    d=json.load(open('${CLASSIC_WORK}/sel.json'))
    r=(d.get('data') or {}).get('result') or []
    print(sum(len(s.get('values') or []) for s in r if isinstance(s,dict)))
except Exception:
    print(0)
" 2>/dev/null)"
    if [[ "$CLASSIC_SEEN" =~ ^[0-9]+$ ]] && (( CLASSIC_SEEN >= CLASSIC_LIMIT )); then
      CLASSIC_TRUNCATED=true
    fi
  done < "$CLASSIC_SELECTORS"

  if [[ "$CLASSIC_QUERY_OK" == "false" && ! -s "${CLASSIC_WORK}/merged.json" ]]; then
    classic_report_only "query_failed"
  else
    if ! python3 - "${CLASSIC_WORK}/merged.json" "$CLASSIC_PHASES" "$CLASSIC_REPORT" \
        "$START_TIME" "$END_TIME" "$CLASSIC_QUERY_OK" "$CLASSIC_TRUNCATED" \
        "$CLASSIC_SELECTOR_COVERAGE" <<'PYEOF'
# classic-idp-resync-parser: hack/classic-idp-telemetry/classic_idp_parser_test.py locates
# this block by the marker above; keep them in step.
import json, re, sys
from datetime import datetime, timezone

merged_path, phases_path, out_path = sys.argv[1], sys.argv[2], sys.argv[3]
start_ts, end_ts = int(sys.argv[4]), int(sys.argv[5])
query_ok = sys.argv[6] == "true"
truncated = sys.argv[7] == "true"
# complete, truncated, or unknown. The step queries a bounded number of cluster ids; when
# the run had more, the ones left out may have emitted events, so the list cannot be
# presented as the whole of them.
selector_coverage = sys.argv[8]

TAG = "[ROSA CLASSIC IDP]"
EVENT_SCHEMA = "rosa.classic.idp.resync/v1"
OPS = {"source_secret_write", "lease_delete", "sync_identity_provider_write", "syncset_write",
       "resync_attempt"}
OUTCOMES = {"succeeded", "deleted", "not_found", "forbidden", "conflict", "failed", "started"}
FLOWS = {"secret_mapping", "not_yet_selected"}
TOGGLES = {"unavailable"}
TOGGLE_REASONS = {"not_present_in_build"}
# The handoff file is writable by any step in the job, so the published phase name is held to
# the same closed set as every other published value rather than echoed through.
PHASES = {"htpasswd_user_import", "idp_create", "idp_delete"}
# The event carries no identifier at all. Any field outside this set is unexpected.
PAYLOAD_FIELDS = {"schema", "op", "outcome", "flow", "toggle", "toggle_reason", "build",
                  "invocation", "time", "generation", "attempt"}
STAMP = "%Y-%m-%dT%H:%M:%S.%fZ"
# Keys a log pipeline may wrap the service's message in.
ENVELOPE_KEYS = ("message", "msg", "log", "_line")
# Guard against a pathological line; the service's own events are far smaller.
MAX_LINE = 16384

rejected = {k: 0 for k in ("unparsable_envelope", "unwrap_failed", "undecodable_payload",
                           "unknown_schema", "unexpected_field", "unknown_op",
                           "unknown_outcome", "unknown_flow", "unknown_toggle",
                           "invalid_time", "out_of_window", "invalid_generation",
                           "invalid_attempt", "oversize_line", "unknown_phase",
                           "malformed_document", "invalid_response", "unreadable_input")}
anomalies = {"build_not_recorded": 0}
# Rejections that are the collection working as intended rather than data lost: an event
# outside the job's own window is meant to be discarded.
EXPECTED_REJECTIONS = frozenset(("out_of_window",))


def iso(epoch):
    return datetime.fromtimestamp(epoch, tz=timezone.utc).strftime("%Y-%m-%dT%H:%M:%SZ")


def load_phases(path):
    """Bounded sanitized phase windows handed over by the test step: an enum and two stamps
    per line, nothing else. A malformed line is skipped rather than guessed at."""
    windows = []
    try:
        with open(path) as handle:
            for line in handle:
                parts = line.split()
                if len(parts) != 3:
                    continue
                name, began, ended = parts
                if name not in PHASES:
                    continue
                try:
                    lo = datetime.strptime(began, STAMP).replace(tzinfo=timezone.utc)
                    hi = datetime.strptime(ended, STAMP).replace(tzinfo=timezone.utc)
                except ValueError:
                    continue
                if hi >= lo:
                    windows.append((lo, hi, name))
    except OSError:
        return []
    return windows


def phase_of(windows, moment):
    """The test phase a write happened in, or a stated absence. This is what makes an event
    attributable to the import under test rather than to any other write of the same job."""
    if not windows:
        return "phase_unavailable"
    # The narrowest containing window wins, so a nested phase is not swallowed by an outer one.
    best = None
    for lo, hi, name in windows:
        if lo <= moment <= hi and (best is None or (hi - lo) < best[0]):
            best = (hi - lo, name)
    return best[1] if best else "outside_known_phase"


def unwrap(value):
    """Return the service's message, unwrapping a JSON log envelope if there is one. The
    envelope itself is discarded whole: it carries the cluster id used to select this run's
    lines, and may carry any other field a log pipeline chose to attach."""
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


def enum_ok(value, allowed):
    """Membership in a closed set, without assuming the value can be hashed. A payload field
    is whatever the line carried: a list or a dict there would raise TypeError and take the
    whole response down with it, discarding the valid events alongside it."""
    return isinstance(value, str) and value in allowed


def documents(path):
    """The merged file holds one JSON document per query. Decode them in sequence."""
    try:
        with open(path) as handle:
            text = handle.read()
    except OSError:
        # Nothing could be read at all. Counted, so the report is partial rather than an
        # empty list that reads as "no resync ran".
        rejected["unreadable_input"] += 1
        return
    decoder, index, length = json.JSONDecoder(), 0, len(text)
    while index < length:
        while index < length and text[index] in " \t\r\n":
            index += 1
        if index >= length:
            return
        try:
            document, index = decoder.raw_decode(text, index)
        except ValueError:
            # One unreadable response must not discard the others: skip to the next line and
            # keep going, and count it so the collection is reported partial rather than as a
            # clean empty result.
            rejected["malformed_document"] += 1
            newline = text.find("\n", index)
            if newline < 0:
                return
            index = newline + 1
            continue
        yield document


phases = load_phases(phases_path)
events = []
# Each document is one selector's response, so its ordinal separates events belonging to
# different clusters in a job that ran more than one. It is an opaque position, not an
# identifier, and it is only published when there is more than one group to tell apart.
# The raw ordinal is renumbered after parsing so that documents which yielded no events -
# an empty response, or one that was not a JSON object at all - leave no gap and cannot
# make a single-cluster run look like a multi-cluster one.
for group, telemetry in enumerate(documents(merged_path)):
    # A 200 is not by itself a usable answer: Loki reports a backend failure in the body, and
    # a log pipeline may return something else entirely. An unusable response is counted, so
    # that a report with no events says the query failed rather than that nothing happened.
    if not isinstance(telemetry, dict):
        rejected["invalid_response"] += 1
        continue
    if telemetry.get("status") not in (None, "success"):
        rejected["invalid_response"] += 1
        continue
    data = telemetry.get("data")
    if not isinstance(data, dict):
        rejected["invalid_response"] += 1
        continue
    streams = data.get("result")
    if not isinstance(streams, list):
        rejected["invalid_response"] += 1
        continue
    for stream in streams:
        if not isinstance(stream, dict):
            rejected["unparsable_envelope"] += 1
            continue
        entries = stream.get("values")
        if entries is None:
            continue
        if not isinstance(entries, list):
            # Anything else here is not iterable, or iterates into something unexpected.
            # Counted rather than iterated: a TypeError would end the parse and discard
            # every other selector's events along with this one.
            rejected["unparsable_envelope"] += 1
            continue
        for entry in entries:
            if not isinstance(entry, list) or len(entry) != 2:
                rejected["unparsable_envelope"] += 1
                continue
            if isinstance(entry[1], str) and len(entry[1]) > MAX_LINE:
                rejected["oversize_line"] += 1
                continue
            message = unwrap(entry[1])
            marker = message.find(TAG)
            if marker < 0:
                rejected["unwrap_failed"] += 1
                continue
            # The service's log encoder appends its configured context fields after the
            # message, so the event is not necessarily the end of the line. Decode just the
            # JSON value; the remainder is never read or written.
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
            if not enum_ok(payload.get("op"), OPS):
                rejected["unknown_op"] += 1
                continue
            if not enum_ok(payload.get("outcome"), OUTCOMES):
                rejected["unknown_outcome"] += 1
                continue
            if not enum_ok(payload.get("flow"), FLOWS):
                rejected["unknown_flow"] += 1
                continue
            if not enum_ok(payload.get("toggle"), TOGGLES) or \
                    not enum_ok(payload.get("toggle_reason"), TOGGLE_REASONS):
                rejected["unknown_toggle"] += 1
                continue
            try:
                moment = datetime.strptime(payload.get("time"), STAMP).replace(tzinfo=timezone.utc)
                began = datetime.strptime(payload.get("invocation"), STAMP).replace(tzinfo=timezone.utc)
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
            attempt = payload.get("attempt")
            if not isinstance(attempt, int) or isinstance(attempt, bool) or attempt < 1:
                rejected["invalid_attempt"] += 1
                continue
            build, shape = build_shape(payload.get("build"))
            if shape == "unrecognized":
                anomalies["build_not_recorded"] += 1
            reduced = {"op": payload["op"], "outcome": payload["outcome"],
                       "flow": payload["flow"], "toggle": payload["toggle"],
                       "toggle_reason": payload["toggle_reason"],
                       "invocation": began.strftime(STAMP),
                       "time": moment.strftime(STAMP),
                       "attempt": attempt,
                       "test_phase": phase_of(phases, moment),
                       "cluster_group": group,
                       "build_shape": shape}
            if build is not None:
                reduced["build"] = build
            if generation is not None:
                reduced["generation"] = generation
            events.append(reduced)

# De-duplicate. Each query filters on one cluster id and the selectors are unique, so a line
# belongs to exactly one group; the group ordinal is therefore safe to include in the key,
# and what this collapses is a line repeated within one response.
seen, unique = set(), []
for event in events:
    key = tuple(sorted(event.items()))
    if key in seen:
        continue
    seen.add(key)
    unique.append(event)
observed = sorted({recorded["cluster_group"] for recorded in unique})
dense = {raw: index for index, raw in enumerate(observed)}
for recorded in unique:
    if len(observed) < 2:
        recorded.pop("cluster_group", None)
    else:
        recorded["cluster_group"] = dense[recorded["cluster_group"]]
unique.sort(key=lambda e: (e.get("cluster_group", 0), e["invocation"], e["time"], e["attempt"]))

# Anything dropped other than an expected discard is data this report does not have, so the
# list cannot be presented as complete - and an empty list must not read as "no resync ran".
lost = sum(count for reason, count in rejected.items()
           if reason not in EXPECTED_REJECTIONS)

# A loss outranks a bound: "something was lost" is the stronger statement, and both bounds
# stay readable in the coverage fields whichever status is reported.
if not query_ok or lost:
    status = "partial"
elif truncated or selector_coverage == "truncated":
    status = "truncated"
elif unique:
    status = "collected"
else:
    status = "no_events_in_window"

with open(out_path, "w") as handle:
    json.dump({"schema": "rosa.classic.idp.resync.report/v1",
               "window": {"start": iso(start_ts), "end": iso(end_ts)},
               "collection": {"status": status,
                              "phase_windows": "present" if phases else "unavailable",
                              "selector_coverage": selector_coverage,
                              "result_coverage":
                                  "truncated" if truncated else "complete"},
               "events": unique, "rejected": rejected, "anomalies": anomalies},
              handle, indent=2)
print(f"  Classic IDP resync: {status}, {len(unique)} event(s), "
      f"{sum(rejected.values())} rejected")
PYEOF
    then
      classic_report_only "parse_failed"
    fi
  fi
fi
echo "  Output: ${CLASSIC_REPORT}"
