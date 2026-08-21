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
CATALOG_NAME="art-operators-nightly-catalog-source"

if oc get nmstate nmstate -n "${NMSTATE_NS}" >/dev/null 2>&1; then
  echo "NMState is already installed"
  oc get csv -n "${NMSTATE_NS}"
  oc get pods -n "${NMSTATE_NS}"
  exit 0
fi

# Nightly payloads do not publish kubernetes-nmstate-operator in GA redhat-operators.
# Use the public ART nightly index (same source as
# hack/ocp-install-nightly-art-operators.sh) without Brew employee tokens.
# CatalogSource pattern matches openshift-qe-installer-bm-day2-cnv.
if [ -z "${NMSTATE_CATALOG_IMAGE}" ]; then
  OCP_VERSION=$(oc get clusterversion version -o jsonpath='{.status.desired.version}' | cut -d '.' -f 1,2)
  NMSTATE_CATALOG_IMAGE="quay.io/openshift-release-dev/ocp-release-nightly:iib-int-index-art-operators-${OCP_VERSION}"
fi
echo "Using NMState catalog image ${NMSTATE_CATALOG_IMAGE}"

cat << EOF | oc apply -f -
apiVersion: operators.coreos.com/v1alpha1
kind: CatalogSource
metadata:
  name: ${CATALOG_NAME}
  namespace: openshift-marketplace
spec:
  sourceType: grpc
  image: ${NMSTATE_CATALOG_IMAGE}
  displayName: ART Operators Nightly Index
  publisher: Red Hat
  updateStrategy:
    registryPoll:
      interval: 8h
EOF

oc wait --for=jsonpath='{.status.connectionState.lastObservedState}'=READY \
  catalogsource/"${CATALOG_NAME}" -n openshift-marketplace --timeout=10m

STARTING_CSV=$(oc get packagemanifest -l catalog="${CATALOG_NAME}" -n openshift-marketplace -o jsonpath="{$.items[?(@.metadata.name=='${NMSTATE_PACKAGE}')].status.channels[?(@.name==\"${NMSTATE_CHANNEL}\")].currentCSV}")
if [ -z "${STARTING_CSV}" ]; then
  echo "Failed to resolve currentCSV for ${NMSTATE_PACKAGE} channel ${NMSTATE_CHANNEL} from ${CATALOG_NAME}"
  oc get packagemanifest -l catalog="${CATALOG_NAME}" -n openshift-marketplace
  oc get packagemanifest "${NMSTATE_PACKAGE}" -n openshift-marketplace -o yaml || true
  exit 1
fi
echo "Installing ${NMSTATE_PACKAGE} startingCSV=${STARTING_CSV}"

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
  source: ${CATALOG_NAME}
  sourceNamespace: openshift-marketplace
  startingCSV: ${STARTING_CSV}
EOF

until oc get csv -n "${NMSTATE_NS}" "${STARTING_CSV}" >/dev/null 2>&1; do
  echo "Waiting for CSV ${STARTING_CSV}"
  sleep 5
done
oc wait --timeout=10m -n "${NMSTATE_NS}" csv "${STARTING_CSV}" --for=jsonpath='{.status.phase}'=Succeeded

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
