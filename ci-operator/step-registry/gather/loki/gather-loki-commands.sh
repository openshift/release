#!/bin/bash -x

set -o nounset
set -o errexit
set -o pipefail

export LOKI_ADDR=http://localhost:3100
export LOKI_ENDPOINT=${LOKI_ADDR}/loki/api/v1

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
  dataline=$(curl -s \
    --data-urlencode "query={filename=\"${filename}\"}" \
    --data-urlencode "limit=1" \
    --data-urlencode "start=0" \
    ${LOKI_ENDPOINT}/query_range)

  ns=$(echo "${dataline}" | jq -r .data.result[0].stream.namespace)
  pod_name=$(echo "${dataline}" | jq -r .data.result[0].stream.instance)
  container_name=$(echo "${dataline}" | jq -r .data.result[0].stream.container_name)
  # /var/log/pods/openshift-sdn_sdn-pstzd_34bbaea8-15dc-4d2b-8cfc-5d1631450605/install-cni-plugins/0.log
  container_pos=$(basename "${filename}")

  # // ns/name/timestamp-uuid/containername.log
  mkdir -p "/tmp/loki-container-logs/${ns}/${pod_name}"
  target="/tmp/loki-container-logs/${ns}/${pod_name}/${container_name}_${container_pos}"

  # TODO(jchaloup): get pod create timestamp from labelscl
  # local lokits
  # lokits=$(echo ${dataline} | jq -r 'select (.data!=null) | select (.data.result!=null) | select (.data.result[0].values!=null) | select (.data.result[0].values[0]!=null) | select (.data.result[0].values[0][0]!=null) | .data.result[0].values[0][0]')
  # if [[ -n "${lokits}" ]]; then
  #   container_date="$(date -u -d @${lokits:0:10} +'%Y-%m-%dT%H:%M:%S')"
  #   echo "container_date: ${container_date}"
  #   mkdir -p "/tmp/loki-container-logs/$ns/$pod_name/${container_date}"
  #   target="/tmp/loki-container-logs/$ns/$pod_name/${container_date}/$container_name"_"$container_pos"
  # fi

  # 2020-04-16T18:23:30+02:00 {} 2020-04-16T16:23:29.778263432+00:00 stderr F I0416 16:23:29.778201       1 sync.go:53] Synced up all machine-api-controller components
  timeout 1m curl -s \
    --data-urlencode "query={filename=\"${filename}\"}" \
    --data-urlencode "limit=10000000" \
    --data-urlencode "start=0" \
    ${LOKI_ENDPOINT}/query_range | jq -r '.data.result[0].values[][1]' | tac >"${target}"

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

if test ! -f "${KUBECONFIG}"
then
	echo "No kubeconfig, so no point in gathering loki logs."
	exit 0
fi

mkdir -p /tmp/loki-container-logs
mkdir -p "${ARTIFACT_DIR}/loki-container-logs"

echo "Checking if 'loki' namespace exists"
if [[ $(oc get ns -o json | jq '.items[].metadata.name' | grep '"loki"' | wc -l) -eq 0 ]]; then
  echo "Namespace 'loki' not found, skipping"
  exit 0
fi

oc port-forward -n loki loki-0 3100:3100 &
ocpordforwardpid="$!"

echo "Waiting for oc port-forward -n loki loki-0 3100:3100 connection"
timeout 30s bash -c "while [[ \"\$(curl -s -o /dev/null -w '%{http_code}' ${LOKI_ADDR}/ready)\" != \"200\" ]]; do echo \"Waiting...\"; sleep 1s; done"

if [[ "$(curl -s -o /dev/null -w '%{http_code}' ${LOKI_ADDR}/ready)" != "200" ]]; then
  echo "Timeout waiting for oc port-forward -n loki loki-0 3100:3100 connection"
  oc get pods -n loki
  oc describe pod -n loki
  kill ${ocpordforwardpid}
  exit 1
fi

curl -s ${LOKI_ENDPOINT}/label/filename/values --data-urlencode "start=0" > /tmp/filenames.json
# curl gives {"status":"success"} in some cases
while [[ -z "$(jq 'select (.data!=null) | .data[]' < /tmp/filenames.json)" ]]; do
  cat /tmp/filenames.json
  oc get pods -n loki
  oc describe pod -n loki
  sleep 10s
  curl -s ${LOKI_ENDPOINT}/label/filename/values --data-urlencode "start=0" > /tmp/filenames.json
done


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

kill ${ocpordforwardpid}

tar -czf "${ARTIFACT_DIR}/loki-container-logs/loki-container-logs.tar.gz" -C /tmp/ loki-container-logs
tar -tf "${ARTIFACT_DIR}/loki-container-logs/loki-container-logs.tar.gz"
