#!/bin/bash -x

set -o nounset
set -o errexit
set -o pipefail

export LOKI_ADDR=http://localhost:3100
export LOKI_ENDPOINT=${LOKI_ADDR}/loki/api/v1

function queue() {
  local TARGET="${1}"
  shift
  local LIVE
  LIVE="$(jobs | wc -l)"
  while [[ "${LIVE}" -ge 45 ]]; do
    sleep 1
    LIVE="$(jobs | wc -l)"
  done
  echo "${@}"
  if [[ -n "${FILTER:-}" ]]; then
    "${@}" | "${FILTER}" >"${TARGET}" &
  else
    "${@}" >"${TARGET}" &
  fi
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

echo "Flushing loki data on disk"
curl -s -X POST ${LOKI_ENDPOINT}/flush

kill ${ocpordforwardpid}

echo "Backup loki index and chunks ..."
queue ${ARTIFACT_DIR}/loki-container-logs/loki-data.tar.gz oc --insecure-skip-tls-verify exec -n loki loki-0 -- tar cvzf - -C /data .
wait
