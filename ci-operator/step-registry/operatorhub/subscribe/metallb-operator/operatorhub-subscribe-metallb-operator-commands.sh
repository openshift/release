#!/bin/bash

set -o nounset
set -o errexit
set -o pipefail

# Check if a custom redhat-operators CatalogSource was created and use it
if [[ -f "${SHARED_DIR}/redhat_operators_catalog_source_name" ]]; then
  CUSTOM_CATALOG_SOURCE=$(cat "${SHARED_DIR}/redhat_operators_catalog_source_name")
  echo "Found custom CatalogSource name: ${CUSTOM_CATALOG_SOURCE}"
  METALLB_OPERATOR_SUB_SOURCE="${CUSTOM_CATALOG_SOURCE}"
  
  # Also derive the channel from the CatalogSource name if not explicitly set or using default
  # CatalogSource name format: redhat-operators-v4-20 -> extract version -> stable
  if [[ "${METALLB_OPERATOR_SUB_CHANNEL}" == "stable" ]]; then
    # MetalLB uses "stable" channel, not version-specific, so we keep it as is
    echo "MetalLB uses 'stable' channel, keeping it unchanged"
  fi
fi

if [[ -z "${METALLB_OPERATOR_SUB_INSTALL_NAMESPACE}" ]]; then
  echo "ERROR: INSTALL_NAMESPACE is not defined"
  exit 1
fi

if [[ -z "${METALLB_OPERATOR_SUB_PACKAGE}" ]]; then
  echo "ERROR: PACKAGE is not defined"
  exit 1
fi

if [[ -z "${METALLB_OPERATOR_SUB_CHANNEL}" ]]; then
  echo "ERROR: CHANNEL is not defined"
  exit 1
fi

# oc apply GETs the object before writing it. On compact baremetal management
# clusters that GET times out while ODF is still reconciling etcd, and set -e
# then exits before the Subscription exists. Retry only those transient
# apiserver/proxy failures. Re-applying a Namespace, OperatorGroup, or
# Subscription is safe.
TRANSIENT_API_RE='etcdserver: request timed out|etcdserver: leader changed|context deadline exceeded|the server is currently unable to handle the request|etcdserver: too many requests|http2: client connection lost|connection reset by peer|unable to return a response in the time allotted|Error from server \(Timeout\)|Internal Server Error|i/o timeout|TLS handshake timeout'
API_RETRY_DEADLINE=0

# Called in the current shell. A command substitution would run this in a
# subshell and the deadline would never stick.
start_api_retry_budget() {
  if [[ "${API_RETRY_DEADLINE}" -eq 0 ]]; then
    API_RETRY_DEADLINE=$((SECONDS + 1200))
  fi
}

# Wait until namespace reads succeed three times in a row. A single success
# still races the etcd stall that timed out "get namespaces".
wait_for_api() {
  local deadline=$((SECONDS + $1))
  local stable=0
  while (( SECONDS < deadline )); do
    if oc get namespace kube-system --request-timeout=15s >/dev/null 2>&1; then
      stable=$((stable + 1))
      echo "API read probe succeeded (${stable}/3)"
      if (( stable >= 3 )); then
        return 0
      fi
    else
      stable=0
      echo "API read probe failed, waiting 15s..."
    fi
    sleep 15
  done
  return 1
}

oc_apply_with_retry() {
  local manifest log rc attempt remaining
  manifest="$(cat)"
  log="$(mktemp)"
  rc=1
  for attempt in $(seq 1 6); do
    set +e
    printf '%s\n' "${manifest}" | oc apply --request-timeout=60s -f - >"${log}" 2>&1
    rc=$?
    set -e
    cat "${log}"
    if [[ "${rc}" -eq 0 ]]; then
      rm -f "${log}"
      return 0
    fi
    if ! grep -Eq "${TRANSIENT_API_RE}" "${log}"; then
      echo "oc apply failed with a non-retryable error"
      rm -f "${log}"
      return "${rc}"
    fi
    if [[ "${attempt}" -eq 6 ]]; then
      break
    fi
    start_api_retry_budget
    remaining=$((API_RETRY_DEADLINE - SECONDS))
    if (( remaining < 0 )); then
      remaining=0
    fi
    if [[ "${remaining}" -eq 0 ]]; then
      echo "API retry budget exhausted"
      break
    fi
    echo "oc apply hit a transient API error (attempt ${attempt}/6). Waiting up to ${remaining}s for the API before retrying."
    if ! wait_for_api "${remaining}"; then
      echo "API did not recover before the retry budget elapsed"
      break
    fi
  done
  echo "oc apply failed after ${attempt} attempts on a transient API error"
  rm -f "${log}"
  return "${rc}"
}

echo "Installing ${METALLB_OPERATOR_SUB_PACKAGE} from channel: ${METALLB_OPERATOR_SUB_CHANNEL} in source: ${METALLB_OPERATOR_SUB_SOURCE} into ${METALLB_OPERATOR_SUB_INSTALL_NAMESPACE}"

# create the install namespace
oc_apply_with_retry <<EOF
apiVersion: v1
kind: Namespace
metadata:
  name: "${METALLB_OPERATOR_SUB_INSTALL_NAMESPACE}"
  labels:
    openshift.io/cluster-monitoring: "true"
EOF

# deploy new operator group
oc_apply_with_retry <<EOF
apiVersion: operators.coreos.com/v1
kind: OperatorGroup
metadata:
  name: "${METALLB_OPERATOR_SUB_INSTALL_NAMESPACE}"
  namespace: "${METALLB_OPERATOR_SUB_INSTALL_NAMESPACE}"
spec: {}
EOF

# subscribe to the operator
oc_apply_with_retry <<EOF
apiVersion: operators.coreos.com/v1alpha1
kind: Subscription
metadata:
  name: "${METALLB_OPERATOR_SUB_PACKAGE}"
  namespace: "${METALLB_OPERATOR_SUB_INSTALL_NAMESPACE}"
spec:
  channel: "${METALLB_OPERATOR_SUB_CHANNEL}"
  installPlanApproval: Automatic
  name: "${METALLB_OPERATOR_SUB_PACKAGE}"
  source: "${METALLB_OPERATOR_SUB_SOURCE}"
  sourceNamespace: openshift-marketplace
EOF

RETRIES=30
CSV=
errlog="$(mktemp)"
for i in $(seq "${RETRIES}") max; do
  [[ "${i}" == "max" ]] && break
  sleep 30
  if [[ -z "${CSV}" ]]; then
    echo "[Retry ${i}/${RETRIES}] The subscription is not yet available. Trying to get it..."
    set +e
    CSV=$(oc get subscription -n "${METALLB_OPERATOR_SUB_INSTALL_NAMESPACE}" "${METALLB_OPERATOR_SUB_PACKAGE}" --request-timeout=30s -o jsonpath='{.status.installedCSV}' 2>"${errlog}")
    get_rc=$?
    set -e
    if [[ "${get_rc}" -ne 0 ]]; then
      echo "subscription query failed, checking again in 30 seconds: $(tr '\n' ' ' < "${errlog}")"
      CSV=
    fi
    continue
  fi

  set +e
  phase=$(oc get csv -n "${METALLB_OPERATOR_SUB_INSTALL_NAMESPACE}" "${CSV}" --request-timeout=30s -o jsonpath='{.status.phase}' 2>"${errlog}")
  get_rc=$?
  set -e
  if [[ "${get_rc}" -ne 0 ]]; then
    echo "Try ${i}/${RETRIES}: csv query failed, checking again in 30 seconds: $(tr '\n' ' ' < "${errlog}")"
    continue
  fi
  if [[ "${phase}" == "Succeeded" ]]; then
    echo "${METALLB_OPERATOR_SUB_PACKAGE} is deployed"
    break
  fi
  echo "Try ${i}/${RETRIES}: ${METALLB_OPERATOR_SUB_PACKAGE} is not deployed yet. Checking again in 30 seconds"
done
rm -f "${errlog}"

if [[ "$i" == "max" ]]; then
  echo "Error: Failed to deploy ${METALLB_OPERATOR_SUB_PACKAGE}"
  echo "subscription YAML"
  oc get subscription "${METALLB_OPERATOR_SUB_PACKAGE}" -n "${METALLB_OPERATOR_SUB_INSTALL_NAMESPACE}" -o yaml || true
  if [[ -n "${CSV}" ]]; then
    echo "csv ${CSV} YAML"
    oc get csv "${CSV}" -n "${METALLB_OPERATOR_SUB_INSTALL_NAMESPACE}" -o yaml || true
    echo
    echo "csv ${CSV} Describe"
    oc describe csv "${CSV}" -n "${METALLB_OPERATOR_SUB_INSTALL_NAMESPACE}" || true
  fi
  exit 1
fi

echo "successfully installed ${METALLB_OPERATOR_SUB_PACKAGE}"
