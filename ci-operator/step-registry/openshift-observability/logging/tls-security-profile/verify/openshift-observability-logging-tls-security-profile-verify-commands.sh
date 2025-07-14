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

echo "Comparing current TLS profile to expected..."

if ! current=$(oc get apiserver cluster -o jsonpath='{.spec.tlsSecurityProfile}' | jq -c .); then
  echo "ERROR: Failed to retrieve current TLS profile from APIServer."
  exit 1
fi

if ! expected=$(echo "${LOGGING_TLS_SECURITY_PROFILE}" | jq -c .); then
  echo "ERROR: Failed to parse expected TLS profile."
  exit 1
fi

echo "Expected: ${expected}"
echo "Current:  ${current}"

if [[ "${current}" != "${expected}" ]]; then
  echo "ERROR: TLS Security Profile does not match expected configuration."
  exit 1
fi

echo "TLS Security Profile matches expected configuration."
