#!/usr/bin/env bash

set -o errexit
set -o nounset
set -o pipefail
set -x

: "${LOKI_NAMESPACE:=netobserv}"
: "${LOKI_SERVICE:=loki}"
if [[ -z "${LOKI_QUERY:-}" ]]; then
  LOKI_QUERY='{K8S_FlowLayer="infra", FlowDirection="1", SrcK8S_Namespace=~"^openshift-.*"} | json | (DstSubnetLabel="" and SrcSubnetLabel="Pods" and __error__="")'
fi
: "${LOKI_STEP:=30s}"

start_file="${SHARED_DIR}/e2e_start_epoch"
if [[ ! -s "${start_file}" ]]; then
  echo "Missing start epoch file: ${start_file}" >&2
  exit 1
fi
start_epoch=$(cat "${start_file}")

# Log the start epoch for debugging
echo "Using start_epoch from file: ${start_epoch}"

end_epoch=$(date +%s)

# Best-effort: ensure Loki is up
oc -n "${LOKI_NAMESPACE}" wait --for=condition=Ready --timeout=300s pod -l app=loki || true

# Port-forward and query
oc -n "${LOKI_NAMESPACE}" port-forward svc/"${LOKI_SERVICE}" 3100:3100 >/tmp/loki-pf.log 2>&1 &
pf_pid=$!
trap 'kill ${pf_pid}' EXIT
sleep 5

out_json="${ARTIFACT_DIR}/loki-query-range.json"

echo "Querying Loki for the time window: ${start_epoch} to ${end_epoch}"
echo "LOKI_QUERY: '${LOKI_QUERY}'"

curl -sG "http://127.0.0.1:3100/loki/api/v1/query_range" \
  --data-urlencode "query=${LOKI_QUERY}" \
  --data-urlencode "start=${start_epoch}" \
  --data-urlencode "end=${end_epoch}" \
  --data-urlencode "step=${LOKI_STEP}" \
  > "${out_json}"

#echo "Waiting for 2 hours to ensure data is ingested into Loki"
#sleep 2h # wait for the data to be ingested into Loki

# Process the results: group by (SrcK8S_Namespace, SrcK8S_OwnerName, SrcK8S_Name, SrcPort, Proto) and deduplicate
processed_json="${ARTIFACT_DIR}/loki-query-range-grouped.json"
jq -c '
  # Extract all log entries from all streams and parse JSON log lines
  [.data.result[].values[][1] | fromjson] |
  # Select only the required fields for each entry
  map({
    SrcK8S_Namespace: .SrcK8S_Namespace,
    SrcK8S_OwnerName: .SrcK8S_OwnerName,
    SrcK8S_Name: .SrcK8S_Name,
    SrcPort: .SrcPort,
    Proto: .Proto,
    DstK8S_OwnerType: .DstK8S_OwnerType,
    DstK8S_OwnerName: .DstK8S_OwnerName,
    DstAddr: .DstAddr,
    DstPort: .DstPort
  }) |
  # Remove duplicates based on the combination of all 9 fields
  unique_by([.SrcK8S_Namespace, .SrcK8S_OwnerName, .SrcK8S_Name, .SrcPort, .Proto, .DstK8S_OwnerType, .DstK8S_OwnerName, .DstAddr, .DstPort]) |
  # Group by the combination of (SrcK8S_Namespace, SrcK8S_OwnerName, SrcK8S_Name, SrcPort, Proto)
  group_by([.SrcK8S_Namespace, .SrcK8S_OwnerName, .SrcK8S_Name, .SrcPort, .Proto]) |
  # Create an object with group key and entries
  map({
    group: {
      SrcK8S_Namespace: .[0].SrcK8S_Namespace,
      SrcK8S_OwnerName: .[0].SrcK8S_OwnerName,
      SrcK8S_Name: .[0].SrcK8S_Name,
      SrcPort: .[0].SrcPort,
      Proto: .[0].Proto
    },
    entries: .
  })
' "${out_json}" > "${processed_json}" || {
  echo "Failed to process Loki results" >&2
  # Fallback: try without grouping if jq processing fails
  jq '.' "${out_json}" > "${processed_json}" || true
}

# Validate and show processing statistics
if jq -e '. | length > 0' "${processed_json}" >/dev/null 2>&1; then
  echo "Processing summary:"
  echo "  Total groups: $(jq '. | length' "${processed_json}")"
  echo "  Total unique entries: $(jq '[.[].entries[]] | length' "${processed_json}")"
  echo "  Sample groups:"
  jq -r '.[0:3] | .[] | "    - \(.group.SrcK8S_Namespace)/\(.group.SrcK8S_OwnerName)/\(.group.SrcK8S_Name):\(.group.SrcPort)/\(.group.Proto) -> \(.entries | length) unique destinations"' "${processed_json}" || true
else
  echo "Warning: Processed JSON appears to be empty or invalid" >&2
fi

# Convert to CSV format
csv_file="${ARTIFACT_DIR}/loki-query-range-grouped.csv"
if jq -e '. | length > 0' "${processed_json}" >/dev/null 2>&1; then
  # Flatten all entries from all groups and convert to CSV
  jq -r '
    # Extract all entries from all groups
    [.[].entries[]] |
    # CSV header
    ["SrcK8S_Namespace", "SrcK8S_OwnerName", "SrcK8S_Name", "SrcPort", "Proto", "DstK8S_OwnerType", "DstK8S_OwnerName", "DstAddr", "DstPort"],
    # CSV rows
    .[] | [.SrcK8S_Namespace, .SrcK8S_OwnerName, .SrcK8S_Name, .SrcPort, .Proto, .DstK8S_OwnerType, .DstK8S_OwnerName, .DstAddr, .DstPort] |
    @csv
  ' "${processed_json}" > "${csv_file}" || {
    echo "Failed to generate CSV file" >&2
  }
  echo "CSV file generated: ${csv_file}"
  echo "  Total rows: $(wc -l < "${csv_file}" | tr -d ' ') (including header)"
else
  echo "Warning: Skipping CSV generation - no data to process" >&2
fi

cat >"${ARTIFACT_DIR}/time_window.json" <<EOF
{
  "e2e_start_epoch": ${start_epoch},
  "e2e_end_epoch": ${end_epoch}
}
EOF

cat "${ARTIFACT_DIR}/time_window.json"
echo ""
echo "Sample of processed results (first group, first 3 entries):"
jq '.[0].entries[0:3]' "${processed_json}" 2>/dev/null || echo "  (No entries to display)"
echo ""
cat "${out_json}" | head -c 2000 || true

# Require some results
if ! jq -e '.data.result | length > 0' "${out_json}" >/dev/null 2>&1; then
  echo "No Loki results for the given time window/query" >&2
fi