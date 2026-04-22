#!/bin/bash
set -o errexit
set -o nounset
set -o pipefail
set -o xtrace

# Start Kusto emulator via podman
podman run -e ACCEPT_EULA=Y -m 4G -d -p 8080:8080 \
  --name kusto-emulator \
  mcr.microsoft.com/azuredataexplorer/kustainer-linux:latest

# Wait for readiness
for i in $(seq 1 60); do
  if curl -sf -X POST -H 'Content-Type: application/json' \
    -d '{"csl":".show cluster"}' http://localhost:8080/v1/rest/mgmt > /dev/null 2>&1; then
    echo "Kusto emulator is ready"
    break
  fi
  sleep 2
done

# Run validation
export KUSTO_ENDPOINT="http://localhost:8080"
make verify-kql
