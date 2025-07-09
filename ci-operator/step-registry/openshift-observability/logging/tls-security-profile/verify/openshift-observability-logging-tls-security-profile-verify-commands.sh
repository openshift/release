#!/bin/bash
set -euo pipefail

if [[ -z "${LOGGING_TLS_SECURITY_PROFILE:-}" ]]; then
  echo "LOGGING_TLS_SECURITY_PROFILE is not set."
  exit 1
fi

echo "Waiting for APIServer 'cluster' to become available..."
for i in {1..30}; do
  if oc get apiserver cluster &>/dev/null; then
    echo "APIServer is available."
    break
  fi
  sleep 5
done

echo "Comparing current TLS profile to expected..."
current=$(oc get apiserver cluster -o jsonpath='{.spec.tlsSecurityProfile}' | jq -c .)
expected=$(echo "${LOGGING_TLS_SECURITY_PROFILE}" | jq -c .)

echo "Expected: ${expected}"
echo "Current:  ${current}"

if [[ "${current}" != "${expected}" ]]; then
  echo "ERROR: TLS Security Profile does not match expected configuration."
  exit 1
fi

echo "TLS Security Profile matches expected configuration."
