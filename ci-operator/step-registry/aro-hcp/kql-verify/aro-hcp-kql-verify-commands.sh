#!/bin/bash
set -o errexit
set -o nounset
set -o pipefail
set -o xtrace

CONTAINER_NAME="kusto-emulator-$$"
EMULATOR_IMAGE="${KUSTO_EMULATOR_IMAGE:-mcr.microsoft.com/azuredataexplorer/kustainer-linux:latest}"
READINESS_TIMEOUT=120

podman run --userns=keep-id -e ACCEPT_EULA=Y -m 4G -d -p 127.0.0.1:8080:8080 \
  --name "${CONTAINER_NAME}" "${EMULATOR_IMAGE}" > /dev/null
trap 'podman rm -f ${CONTAINER_NAME} > /dev/null 2>&1' EXIT

export KUSTO_ENDPOINT="http://localhost:8080"

echo "Waiting for Kusto emulator to be ready (timeout ${READINESS_TIMEOUT}s)..."
ready=false
for i in $(seq 1 $((READINESS_TIMEOUT / 2))); do
  if curl -sf -X POST -H 'Content-Type: application/json' \
    -d '{"csl":".show cluster"}' "${KUSTO_ENDPOINT}/v1/rest/mgmt" > /dev/null 2>&1; then
    ready=true
    break
  fi
  sleep 2
done

if [ "${ready}" != "true" ]; then
  echo "ERROR: Kusto emulator did not become ready within ${READINESS_TIMEOUT}s"
  exit 1
fi
echo "Kusto emulator is ready"

make verify-kql
