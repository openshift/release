#!/bin/bash
set -o errexit
set -o nounset
set -o pipefail

echo "Running GSM reconciler E2E test..."

export GOOGLE_APPLICATION_CREDENTIALS="/tmp/gcp-creds/key.json"

cd cmd/gsm-e2e
exec go test -v -timeout 30m -log-level=info