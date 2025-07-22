#!/bin/bash
set -euo pipefail

if [[ -z "${LOGGING_TLS_SECURITY_PROFILE:-}" ]]; then
  echo "LOGGING_TLS_SECURITY_PROFILE is not set."
  exit 1
fi

echo "Waiting for APIServer 'cluster' to become available..."
retries=30
interval=5
found=false

for ((i=1; i<=retries; i++)); do
  echo "[$i/$retries] Checking if APIServer is available..."

  if output=$(oc get apiserver cluster 2>&1); then
    echo "$output"
    echo "APIServer is available."
    found=true
    break
  else
    echo "$output"
    echo "APIServer not available. Retrying in $interval seconds..."
  fi

  sleep "$interval"
done

if [[ "$found" != "true" ]]; then
  echo "ERROR: Timed out waiting for APIServer 'cluster' to become available."
  exit 1
fi

echo "Fetching .spec block from APIServer..."
spec_block=$(oc get apiserver cluster -o json | jq '.spec')
echo "$spec_block"

echo "Comparing current TLS profile to expected..."

echo "Fetching full .spec block from APIServer..."

spec_block=$(oc get apiserver cluster -o json | jq '.spec')
echo "$spec_block"
