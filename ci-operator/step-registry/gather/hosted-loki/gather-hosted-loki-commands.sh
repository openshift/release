#!/bin/bash

set -o nounset
set -o errexit
set -o pipefail

LOKI_ENDPOINT=https://observatorium.api.stage.openshift.com/api/logs/v1/dptp/loki/api/v1
# Fetch bearer token from SSO
# Note that we don't renew it - 15 mins should be sufficient to fetch all logs
ACCESS_TOKEN=$(curl \
  --request POST \
  --silent \
  --url https://sso.redhat.com/auth/realms/redhat-external/protocol/openid-connect/token \
  --header 'content-type: application/x-www-form-urlencoded' \
  --data grant_type=client_credentials \
  --data client_id="$(cat /var/run/loki-secret/client-id)" \
  --data client_secret="$(cat /var/run/loki-secret/client-secret)" \
  --data scope="openid email" | sed 's/^{.*"access_token":[^"]*"\([^"]*\)".*}/\1/')
readonly ACCESS_TOKEN

# Fetch logs from 4 hours ago
START=$(date --utc --date="4 hours ago" +%s)
readonly START

if test ! -f "${KUBECONFIG}"
then
	echo "No kubeconfig, so no point in gathering loki logs."
	exit 0
fi

CLUSTER_ID=$(oc get clusterversion/version -o=jsonpath='{.spec.clusterID}')
readonly CLUSTER_ID

function getlogs() {
  local filename="${1}"
  if [[ -z "${filename}" ]]; then
    echo "Missing filename"
    return
  fi

  echo "Collecting $filename"

  local dataline
  local container_pos
  local target

  # get ns, podname and container name first
  dataline=$(curl -G -s \
    --header "Authorization: Bearer ${ACCESS_TOKEN}" \
    --data-urlencode "query={filename=\"${filename}\", _id=\"${CLUSTER_ID}\"}" \
    --data-urlencode "limit=1" \
    "${LOKI_ENDPOINT}/query_range")

  ns=$(echo "${dataline}" | jq -r .data.result[0].stream.namespace)
  # Check that filename comes from this cluster
  if [[ "${ns}" == "null" ]]; then return; fi
  pod_name=$(echo "${dataline}" | jq -r .data.result[0].stream.instance)
  container_name=$(echo "${dataline}" | jq -r .data.result[0].stream.container_name)
  # /var/log/pods/openshift-sdn_sdn-pstzd_34bbaea8-15dc-4d2b-8cfc-5d1631450605/install-cni-plugins/0.log
  container_pos=$(basename "${filename}")

  # // ns/name/timestamp-uuid/containername.log
  mkdir -p "/tmp/loki-container-logs/${ns}/${pod_name}"
  target="/tmp/loki-container-logs/${ns}/${pod_name}/${container_name}_${container_pos}"

  # 2020-04-16T18:23:30+02:00 {} 2020-04-16T16:23:29.778263432+00:00 stderr F I0416 16:23:29.778201       1 sync.go:53] Synced up all machine-api-controller components
  timeout 1m curl -G -s \
    --header "Authorization: Bearer ${ACCESS_TOKEN}" \
    --data-urlencode "query={filename=\"${filename}\", _id=\"${CLUSTER_ID}\"}" \
    --data-urlencode "start=${START}" \
    "${LOKI_ENDPOINT}/query_range" | jq -r '.data.result[0].values[][1]' | tac >"${target}"
  echo "Collected $filename"
}

function queue() {
  local filename="${1}"
  shift
  local live
  live="$(jobs | wc -l)"
  while [[ "${live}" -ge 15 ]]; do
    sleep 1
    live="$(jobs | wc -l)"
  done
  echo "${@}"

  getlogs "${filename}" &
}

mkdir -p /tmp/loki-container-logs
mkdir -p "${ARTIFACT_DIR}/loki-container-logs"

curl -G -s \
  --header "Authorization: Bearer ${ACCESS_TOKEN}" \
  --data-urlencode "start=${START}" \
  "${LOKI_ENDPOINT}/label/filename/values" > /tmp/filenames.json
for filename in $(jq -r '.data[]' < /tmp/filenames.json)
do
  queue "${filename}"
done

live="$(jobs | wc -l)"
while [[ "${live}" -gt 1 ]]; do
  echo "Waiting for ${live} jobs to finish"
  jobs
  sleep 1s
  live="$(jobs | wc -l)"
done

tar -czf "${ARTIFACT_DIR}/loki-container-logs/loki-container-logs.tar.gz" -C /tmp/ loki-container-logs
tar -tf "${ARTIFACT_DIR}/loki-container-logs/loki-container-logs.tar.gz"
