#!/usr/bin/env bash

set -o errexit
set -o nounset
set -o pipefail
set -x

: "${LOKI_NAMESPACE:=netobserv}"
: "${LOKI_SERVICE:=loki}"
: "${LOKI_QUERY:={K8S_FlowLayer=\"infra\", FlowDirection=\"1\", SrcK8S_Namespace=~\"^openshift-.*\"} | json | DstSubnetLabel=\"\" | SrcSubnetLabel=\"Pods\" | __error__=\"\"}"
: "${LOKI_STEP:=30s}"



start_file="${SHARED_DIR}/e2e_start_epoch"
if [[ ! -s "${start_file}" ]]; then
  echo "Missing start epoch file: ${start_file}" >&2
  exit 1
fi
start_epoch=$(cat "${start_file}")
end_epoch=$(date +%s)

# Best-effort: ensure Loki is up
oc -n "${LOKI_NAMESPACE}" wait --for=condition=Ready --timeout=300s pod -l app=loki || true

# Port-forward and query
oc -n "${LOKI_NAMESPACE}" port-forward "svc/${LOKI_SERVICE}" 3100:3100 >/tmp/loki-pf.log 2>&1 &
pf_pid=$!
trap 'kill ${pf_pid}' EXIT
sleep 5

out_json="${ARTIFACT_DIR}/loki-query-range.json"

curl -sG "http://127.0.0.1:3100/loki/api/v1/query_range" \
  --data-urlencode "query=${LOKI_QUERY}" \
  --data-urlencode "start=${start_epoch}" \
  --data-urlencode "end=${end_epoch}" \
  --data-urlencode "step=${LOKI_STEP}" \
  > "${out_json}"

# Process the results: group by SrcK8S_Namespace and remove duplicates
processed_json="${ARTIFACT_DIR}/loki-query-range-grouped.json"
jq -c '
  # Extract all log entries from all streams and parse JSON log lines
  [.data.result[].values[][1] | fromjson] |
  # Remove duplicates based on all fields (using tostring as key for comparison)
  unique_by(tostring) |
  # Group by SrcK8S_Namespace
  group_by(.SrcK8S_Namespace) |
  # Create an object with namespace as key and entries as value
  map({key: (.[0].SrcK8S_Namespace // "unknown"), value: .}) |
  from_entries
' "${out_json}" > "${processed_json}" || {
  echo "Failed to process Loki results" >&2
  # Fallback: try without grouping if jq processing fails
  jq '.' "${out_json}" > "${processed_json}" || true
}

cat >"${ARTIFACT_DIR}/time_window.json" <<EOF
{
  "e2e_start_epoch": ${start_epoch},
  "e2e_end_epoch": ${end_epoch}
}
EOF

cat "${ARTIFACT_DIR}/time_window.json"
cat "${out_json}" | head -c 2000 || true

# Require some results
if ! jq -e '.data.result | length > 0' "${out_json}" >/dev/null 2>&1; then
  echo "No Loki results for the given time window/query" >&2
fi