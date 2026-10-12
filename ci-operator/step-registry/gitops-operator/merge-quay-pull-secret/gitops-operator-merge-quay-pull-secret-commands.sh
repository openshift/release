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

wait_for_mcp_rollout() {
  local mcp="$1"
  local updating updated
  local counter=0
  local observation_seconds=120

  echo "Waiting up to ${observation_seconds}s for MCP ${mcp} to react to pull-secret update..."
  while [[ ${counter} -lt ${observation_seconds} ]]; do
    if ! updating=$(oc get mcp "${mcp}" -o jsonpath='{.status.conditions[?(@.type=="Updating")].status}'); then
      echo "Failed to read Updating condition for MCP ${mcp}" >&2
      exit 1
    fi

    if [[ "${updating}" == "True" ]]; then
      echo "MCP ${mcp} rollout started (Updating=True)"
      oc wait "mcp/${mcp}" --for=condition=UPDATED=True --timeout=600s
      return 0
    fi

    sleep 5
    counter=$((counter + 5))
  done

  if ! updated=$(oc get mcp "${mcp}" -o jsonpath='{.status.conditions[?(@.type=="Updated")].status}'); then
    echo "Failed to read Updated condition for MCP ${mcp}" >&2
    exit 1
  fi

  if [[ "${updating}" == "False" && "${updated}" == "True" ]]; then
    echo "MCP ${mcp} remained converged after ${observation_seconds}s; skipping rollout wait"
    return 0
  fi

  oc wait "mcp/${mcp}" --for=condition=UPDATING=True --timeout=300s
  oc wait "mcp/${mcp}" --for=condition=UPDATED=True --timeout=600s
}

NUM_WORKERS="$(oc get mcp worker -ojsonpath='{.status.machineCount}')"
if [[ "${NUM_WORKERS}" != "0" ]]; then
  wait_for_mcp_rollout worker
else
  echo "SNO or compact cluster; skipping worker MCP rollout wait"
fi
wait_for_mcp_rollout master
