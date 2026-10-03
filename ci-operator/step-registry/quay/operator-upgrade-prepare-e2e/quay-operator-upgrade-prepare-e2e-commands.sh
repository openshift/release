#!/bin/bash
set -euo pipefail

NAMESPACE="${QUAY_UPGRADE_QUAY_NAMESPACE:-quay}"
REGISTRY="${QUAY_UPGRADE_QUAY_REGISTRY:-quay}"
TIMEOUT="${QUAY_UPGRADE_READINESS_TIMEOUT:-15m}"
[[ "${TIMEOUT}" =~ ^([1-9][0-9]*)([smh])$ ]] || { echo "ERROR: QUAY_UPGRADE_READINESS_TIMEOUT must be a positive Ns, Nm, or Nh duration" >&2; exit 1; }
case "${BASH_REMATCH[2]}" in s) seconds="${BASH_REMATCH[1]}";; m) seconds="$((BASH_REMATCH[1] * 60))";; h) seconds="$((BASH_REMATCH[1] * 3600))";; esac
deadline=$(( $(date +%s) + seconds ))
while (( $(date +%s) < deadline )); do
  available="$(oc get quayregistry -n "${NAMESPACE}" "${REGISTRY}" -o jsonpath='{.status.conditions[?(@.type=="Available")].status}' 2>/dev/null || true)"
  endpoint="$(oc get quayregistry -n "${NAMESPACE}" "${REGISTRY}" -o jsonpath='{.status.registryEndpoint}' 2>/dev/null || true)"
  if [[ "${available}" == True && "${endpoint}" =~ ^https?:// ]]; then
    printf '%s\n' "${endpoint}" >"${SHARED_DIR}/quayroute"
    echo "QuayRegistry ${NAMESPACE}/${REGISTRY} is ready for Playwright."
    exit 0
  fi
  sleep 10
done
echo "ERROR: QuayRegistry ${NAMESPACE}/${REGISTRY} did not become Available with an HTTP(S) endpoint within ${TIMEOUT}" >&2
exit 1
