#!/bin/bash
set -o errexit
set -o nounset
set -o pipefail
set -x
cat /etc/os-release

# For disconnected or otherwise unreachable environments, we want to
# have steps use an HTTP(S) proxy to reach the API server. This proxy
# configuration file should export HTTP_PROXY, HTTPS_PROXY, and NO_PROXY
# environment variables, as well as their lowercase equivalents (note
# that libcurl doesn't recognize the uppercase variables).
if test -f "${SHARED_DIR}/proxy-conf.sh"; then
  # shellcheck disable=SC1090
  source "${SHARED_DIR}/proxy-conf.sh"
fi

oc config view
oc projects

NMSTATE_NS="openshift-nmstate"
NMSTATE_PACKAGE="kubernetes-nmstate-operator"

if oc get nmstate nmstate -n "${NMSTATE_NS}" >/dev/null 2>&1; then
  echo "NMState is already installed"
  oc get csv -n "${NMSTATE_NS}"
  oc get pods -n "${NMSTATE_NS}"
  exit 0
fi

echo "Installing ${NMSTATE_PACKAGE} from source ${OPERATOR_SOURCE_INDEX} channel ${NMSTATE_CHANNEL}"

# Install the kubernetes-nmstate operator
cat << EOF | oc apply -f -
apiVersion: v1
kind: Namespace
metadata:
  name: ${NMSTATE_NS}
  labels:
    name: ${NMSTATE_NS}
    openshift.io/cluster-monitoring: "true"
EOF

cat << EOF | oc apply -f -
apiVersion: operators.coreos.com/v1
kind: OperatorGroup
metadata:
  name: ${NMSTATE_NS}
  namespace: ${NMSTATE_NS}
spec:
  targetNamespaces:
  - ${NMSTATE_NS}
EOF

cat << EOF | oc apply -f -
apiVersion: operators.coreos.com/v1alpha1
kind: Subscription
metadata:
  name: ${NMSTATE_PACKAGE}
  namespace: ${NMSTATE_NS}
spec:
  channel: ${NMSTATE_CHANNEL}
  installPlanApproval: Automatic
  name: ${NMSTATE_PACKAGE}
  source: ${OPERATOR_SOURCE_INDEX}
  sourceNamespace: openshift-marketplace
EOF

dump_nmstate_olm() {
  echo "=== NMState OLM diagnostics ==="
  oc get subscription,installplan,csv -n "${NMSTATE_NS}" || true
  oc get packagemanifest "${NMSTATE_PACKAGE}" -n openshift-marketplace -o yaml || true
  oc get catalogsource -n openshift-marketplace || true
}

# Wait for the operator CSV (fail fast if the catalog has no matching package)
WAIT_TIMEOUT_SEC=600
elapsed=0
until kubectl get csv -n "${NMSTATE_NS}" 2>/dev/null | grep -q "${NMSTATE_PACKAGE}"; do
  if [ "${elapsed}" -ge "${WAIT_TIMEOUT_SEC}" ]; then
    echo "Timed out waiting for ${NMSTATE_PACKAGE} CSV from source ${OPERATOR_SOURCE_INDEX}"
    dump_nmstate_olm
    exit 1
  fi
  echo "Waiting for NMState operator (${elapsed}s/${WAIT_TIMEOUT_SEC}s)"
  sleep 10
  elapsed=$((elapsed + 10))
done
kubectl wait --for jsonpath='{.status.phase}'=Succeeded --timeout=10m -n "${NMSTATE_NS}" "$(kubectl get csv -n "${NMSTATE_NS}" -oname | grep "${NMSTATE_PACKAGE}")"

elapsed=0
until oc get crd nmstates.nmstate.io >/dev/null 2>&1; do
  if [ "${elapsed}" -ge "${WAIT_TIMEOUT_SEC}" ]; then
    echo "Timed out waiting for NMState CRD"
    dump_nmstate_olm
    exit 1
  fi
  echo "Waiting for NMState CRD (${elapsed}s/${WAIT_TIMEOUT_SEC}s)"
  sleep 10
  elapsed=$((elapsed + 10))
done

cat << EOF | oc apply -f -
apiVersion: nmstate.io/v1
kind: NMState
metadata:
  name: nmstate
  namespace: ${NMSTATE_NS}
EOF

elapsed=0
until oc get ds -n "${NMSTATE_NS}" nmstate-handler >/dev/null 2>&1; do
  if [ "${elapsed}" -ge "${WAIT_TIMEOUT_SEC}" ]; then
    echo "Timed out waiting for nmstate-handler DaemonSet"
    oc get nmstate -n "${NMSTATE_NS}" -o yaml || true
    oc get pods -n "${NMSTATE_NS}" || true
    exit 1
  fi
  echo "Waiting for nmstate-handler DaemonSet (${elapsed}s/${WAIT_TIMEOUT_SEC}s)"
  sleep 10
  elapsed=$((elapsed + 10))
done
oc rollout status ds/nmstate-handler -n "${NMSTATE_NS}" --timeout=10m
oc get pods -n "${NMSTATE_NS}"
