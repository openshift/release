#!/bin/bash
set -euo pipefail

AUTH_FILE="/var/run/secrets/gitops-quay-credentials/auth"
TMP_DIR="$(mktemp -d)"
trap 'rm -rf "${TMP_DIR}"' EXIT

if [[ ! -r "${AUTH_FILE}" ]]; then
  echo "ERROR: Missing Quay credentials at ${AUTH_FILE}"
  exit 1
fi

if ! oc get secret pull-secret -n openshift-config &>/dev/null; then
  echo "ERROR: openshift-config/pull-secret does not exist"
  exit 255
fi

oc get secret pull-secret -n openshift-config \
  --template='{{index .data ".dockerconfigjson" | base64decode}}' \
  > "${TMP_DIR}/cluster.json"

# Disable tracing while handling credentials
[[ $- == *x* ]] && WAS_TRACING=true || WAS_TRACING=false
set +x

AUTH="$(tr -d '\n\r' < "${AUTH_FILE}")"
if [[ -z "${AUTH}" ]]; then
  echo "ERROR: Quay credentials file is empty"
  exit 1
fi

jq -n --arg auth "${AUTH}" \
  --arg reg "${QUAY_REGISTRY}" \
  '{auths: {($reg): {auth: $auth, email: ""}}}' \
  > "${TMP_DIR}/extra.json"

jq -s '.[0] * .[1]' "${TMP_DIR}/cluster.json" "${TMP_DIR}/extra.json" \
  > "${TMP_DIR}/merged.json"

unset AUTH
$WAS_TRACING && set -x

oc set data secret/pull-secret -n openshift-config \
  --from-file=.dockerconfigjson="${TMP_DIR}/merged.json"

NUM_WORKERS="$(oc get mcp worker -ojsonpath='{.status.machineCount}')"
[[ "${NUM_WORKERS}" != "0" ]] && oc wait mcp worker --for=condition=UPDATING=True --timeout=300s
oc wait mcp master --for=condition=UPDATING=True --timeout=300s
[[ "${NUM_WORKERS}" != "0" ]] && oc wait mcp worker --for=condition=UPDATED=True --timeout=600s
oc wait mcp master --for=condition=UPDATED=True --timeout=600s
