#!/bin/bash

set -o errexit
set -o nounset
set -o pipefail

target="${1:-"errors"}"

query="$( cat docs/dptp-triage-sop/logs/${target}.txt )"
echo "[INFO] Running query: ${query}"
echo "[INFO] Starting log query..."

DATE_CMD=date
if [[ "${OSTYPE}" == "darwin"* ]]; then
  DATE_CMD=gdate
fi

query_id="$( aws --profile openshift-ci-infra --region us-east-1 logs start-query --log-group-name app-ci-pod-logs --start-time "$( ${DATE_CMD} --date '1 day ago' '+%s' )" --end-time "$( ${DATE_CMD} '+%s' )" --query-string "${query}" --query queryId --output text )"
echo "[INFO] Log query id: ${query_id}"
echo "[INFO] Fetching log query results..."
out="$( mktemp /tmp/aws-logs-XXXXXXXXXX )"
while true; do
	if ! aws --profile openshift-ci-infra --region us-east-1 logs get-query-results --query-id "${query_id}" --output json > "${out}" 2>&1; then
		echo "[ERROR] Fetching query results failed:"
		cat "${out}"
		exit 1
	fi
	status="$( jq '.status' --raw-output <"${out}" )"
	if [[ "${status}" == "Running" || "${status}" == "Scheduled" ]]; then
		echo "[INFO] Query found $( jq .statistics.recordsMatched <"${out}" ) matching logs but is not yet not complete, waiting..."
		sleep 10
		continue
	fi
	echo "[INFO] Query finished with status ${status}"
	break
done
echo "[INFO] Found $( jq .statistics.recordsMatched <"${out}" ) matching logs, stored in ${out}"
filtered="$( mktemp /tmp/aws-logs-XXXXXXXXXX )"
docs/dptp-triage-sop/logs/filter.py "${target}" "${out}" > "${filtered}"
echo "[INFO] Filtered to $( jq length <"${filtered}" ) matching logs, stored in ${filtered}"
docs/dptp-triage-sop/logs/table.py "${filtered}"