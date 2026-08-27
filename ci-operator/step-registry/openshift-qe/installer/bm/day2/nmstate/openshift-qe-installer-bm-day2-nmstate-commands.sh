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

# Wait for the operator to be ready
until [ "$(kubectl get csv -n "${NMSTATE_NS}" | grep "${NMSTATE_PACKAGE}" > /dev/null; echo $?)" == 0 ];
  do echo "Waiting for NMState operator"
  sleep 5
done
kubectl wait --for jsonpath='{.status.phase}'=Succeeded --timeout=10m -n "${NMSTATE_NS}" "$(kubectl get csv -n "${NMSTATE_NS}" -oname | grep "${NMSTATE_PACKAGE}")"

until oc get crd nmstates.nmstate.io >/dev/null 2>&1; do
  echo "Waiting for NMState CRD"
  sleep 5
done

cat << EOF | oc apply -f -
apiVersion: nmstate.io/v1
kind: NMState
metadata:
  name: nmstate
  namespace: ${NMSTATE_NS}
EOF

until oc get ds -n "${NMSTATE_NS}" nmstate-handler >/dev/null 2>&1; do
  echo "Waiting for nmstate-handler DaemonSet"
  sleep 5
done
oc rollout status ds/nmstate-handler -n "${NMSTATE_NS}" --timeout=10m
oc get pods -n "${NMSTATE_NS}"
