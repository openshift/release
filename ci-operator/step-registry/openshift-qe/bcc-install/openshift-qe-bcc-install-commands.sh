#!/bin/bash
set -euo pipefail

NAMESPACE="bgp-cloud-connector"
PACKAGE_NAME="bgp-cloud-connector"
CATALOG_SOURCE="redhat-operators"
CATALOG_SOURCE_NAMESPACE="openshift-marketplace"
SUBSCRIPTION_NAME="bgp-cloud-connector"

echo "Installing BGP Cloud Connector operator via OLM Subscription"
echo "  Package:          ${PACKAGE_NAME}"
echo "  CatalogSource:    ${CATALOG_SOURCE}"
echo "  Namespace:        ${NAMESPACE}"

# --- helpers ----------------------------------------------------------------

wait_for_csv() {
  local ns="$1" sub="$2" csv phase
  echo "Waiting for CSV of subscription ${sub} in ${ns} to reach Succeeded ..."
  for i in $(seq 1 60); do
    csv="$(oc get subscription "${sub}" -n "${ns}" \
      -o jsonpath='{.status.installedCSV}' 2>/dev/null || true)"
    if [[ -n "${csv}" ]]; then
      phase="$(oc get csv "${csv}" -n "${ns}" \
        -o jsonpath='{.status.phase}' 2>/dev/null || true)"
      echo "  CSV ${csv} phase: ${phase:-<none>} (${i}/60)"
      if [[ "${phase}" == "Succeeded" ]]; then
        echo "CSV ${csv} reached Succeeded phase"
        return 0
      fi
    else
      echo "  Waiting for installedCSV to appear ... (${i}/60)"
    fi
    sleep 10
  done

  echo "ERROR: CSV for subscription ${sub} did not reach Succeeded within 10 minutes" >&2
  oc get subscription "${sub}" -n "${ns}" -o yaml >&2 || true
  oc get csv -n "${ns}" -o wide >&2 || true
  oc get installplan -n "${ns}" -o wide >&2 || true
  oc get events -n "${ns}" --sort-by='.lastTimestamp' | tail -30 >&2 || true
  return 1
}

# --- namespace --------------------------------------------------------------

echo "=== Creating namespace ${NAMESPACE} ==="
oc create namespace "${NAMESPACE}" --dry-run=client -o yaml | oc apply -f -

# --- OperatorGroup ----------------------------------------------------------

echo "=== Creating OperatorGroup ==="
cat <<EOF | oc apply -f -
apiVersion: operators.coreos.com/v1
kind: OperatorGroup
metadata:
  name: bgp-cloud-connector-operatorgroup
  namespace: ${NAMESPACE}
spec:
  targetNamespaces:
  - ${NAMESPACE}
EOF

# --- Subscription -----------------------------------------------------------

echo "=== Creating Subscription ==="
cat <<EOF | oc apply -f -
apiVersion: operators.coreos.com/v1alpha1
kind: Subscription
metadata:
  name: ${SUBSCRIPTION_NAME}
  namespace: ${NAMESPACE}
spec:
  channel: stable
  installPlanApproval: Automatic
  name: ${PACKAGE_NAME}
  source: ${CATALOG_SOURCE}
  sourceNamespace: ${CATALOG_SOURCE_NAMESPACE}
EOF

# --- wait for CSV -----------------------------------------------------------

wait_for_csv "${NAMESPACE}" "${SUBSCRIPTION_NAME}"

# --- wait for controller deployment ----------------------------------------

echo "=== Waiting for BCC controller-manager deployment to become Available ==="
# Give OLM a moment to create the deployment from the CSV
sleep 10

DEPLOY_NAME=""
for i in $(seq 1 30); do
  DEPLOY_NAME="$(oc get deployments -n "${NAMESPACE}" -o jsonpath='{.items[0].metadata.name}' 2>/dev/null || true)"
  if [[ -n "${DEPLOY_NAME}" ]]; then
    echo "Found deployment: ${DEPLOY_NAME}"
    break
  fi
  echo "  Waiting for deployment to be created ... (${i}/30)"
  sleep 5
done

if [[ -z "${DEPLOY_NAME}" ]]; then
  echo "ERROR: No deployment found in namespace ${NAMESPACE}" >&2
  oc get all -n "${NAMESPACE}" -o wide >&2 || true
  exit 1
fi

if ! oc -n "${NAMESPACE}" wait \
  --for=condition=Available \
  "deployment/${DEPLOY_NAME}" \
  --timeout=5m; then
  echo "ERROR: Deployment ${DEPLOY_NAME} did not become Available" >&2
  oc get deployment "${DEPLOY_NAME}" -n "${NAMESPACE}" -o yaml >&2 || true
  oc get pods -n "${NAMESPACE}" -o wide >&2 || true
  oc get events -n "${NAMESPACE}" --sort-by='.lastTimestamp' | tail -30 >&2 || true
  exit 1
fi

echo "=== BGP Cloud Connector operator installed successfully ==="
oc get deployment,pods -n "${NAMESPACE}" -o wide
