#!/bin/bash

set -o errexit
set -o nounset
set -o pipefail

# this should be an event URL like 
# https://github.com/openshift/ci-tools/pull/2287#pullrequestreview-739614055
target="${1:-""}"

if [[ -z "${target}" ]]; then
	echo "[ERROR] An event URL argument is required. Usage:"
	echo "  $0 <url>"
	exit 1
fi

query="fields \`event-GUID\`
| filter(component=\"hook\")
| filter(url=\"${target}\")
| limit 1
"
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
		sleep 2
		continue
	fi
	echo "[INFO] Query finished with status ${status}"
	break
done
echo "[INFO] Found $( jq .statistics.recordsMatched <"${out}" ) matching logs, stored in ${out}"
event_guid="$( jq '.results[0][] | select(.field=="event-GUID") | .value ' --raw-output < "${out}" )"

query="fields @message
| sort @timestamp desc
| filter(component=\"hook\")
| filter(url=\"${target}\" or \`event-GUID\`=\"${event_guid}\")
"
echo "[INFO] Running query: ${query}"
echo "[INFO] Starting log query..."

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
		sleep 2
		continue
	fi
	echo "[INFO] Query finished with status ${status}"
	break
done
echo "[INFO] Found $( jq .statistics.recordsMatched <"${out}" ) matching logs, stored in ${out}"
results="$( mktemp /tmp/aws-logs-XXXXXXXXXX )"
jq '.results' <"${out}" >"${results}"
docs/dptp-triage-sop/logs/table.py "${results}"