#!/bin/bash

set -o nounset
set -o errexit
set -o pipefail

QUAY_OPERATOR_CHANNEL="$QUAY_OPERATOR_CHANNEL"
QUAY_OPERATOR_SOURCE="$QUAY_OPERATOR_SOURCE"

#Deploy Quay Operator to OCP namespace '${QUAYNAMESPACE}'
cat <<EOF | oc apply -f -
apiVersion: v1
kind: Namespace
metadata:
  name: ${QUAYNAMESPACE}
EOF

cat <<EOF | oc apply -f -
apiVersion: operators.coreos.com/v1
kind: OperatorGroup
metadata:
  name: quay
  namespace: ${QUAYNAMESPACE}
spec:
  targetNamespaces:
  - ${QUAYNAMESPACE}
EOF

SUB=$(
    cat <<EOF | oc apply -f - -o jsonpath='{.metadata.name}'
apiVersion: operators.coreos.com/v1alpha1
kind: Subscription
metadata:
  name: quay-operator
  namespace: ${QUAYNAMESPACE}
spec:
  installPlanApproval: Automatic
  name: quay-operator
  channel: $QUAY_OPERATOR_CHANNEL
  source: $QUAY_OPERATOR_SOURCE
  sourceNamespace: openshift-marketplace
EOF
)

echo "The Quay Operator subscription is $SUB"

for _ in {1..60}; do
    CSV=$(oc -n ${QUAYNAMESPACE} get subscription "$SUB" -o jsonpath='{.status.installedCSV}' || true)
    if [[ -n "$CSV" ]]; then
        if [[ "$(oc -n ${QUAYNAMESPACE} get csv "$CSV" -o jsonpath='{.status.phase}')" == "Succeeded" ]]; then
            echo "Quay ClusterServiceVersion \"$CSV\" is ready"
            break
        fi
    fi
    sleep 10
done

# Wait for the QuayRegistry CRD to be installed by the operator so that the next step
# (e.g. deploy-registry-noobaa) can create QuayRegistry resources without racing.
echo "Waiting for QuayRegistry CRD to be installed..."
for _ in {1..30}; do
    if oc get crd quayregistries.quay.redhat.com &>/dev/null; then
        echo "QuayRegistry CRD is available"
        break
    fi
    sleep 10
done
if ! oc get crd quayregistries.quay.redhat.com &>/dev/null; then
    echo "ERROR: QuayRegistry CRD was not installed after CSV succeeded"
    echo "Dumping operator state for debugging:"
    oc -n "${QUAYNAMESPACE}" get subscription,operatorgroup,csv -o yaml || true
    oc get crd | grep -E 'NAME|quay' || true
    oc -n "${QUAYNAMESPACE}" get pods -o wide || true
    exit 1
fi

# Dump operator state to artifacts for easier debugging if a later step fails
if [[ -n "${ARTIFACT_DIR:-}" ]]; then
    echo "Saving operator diagnostics to ${ARTIFACT_DIR}"
    oc -n "${QUAYNAMESPACE}" get subscription quay-operator -o yaml > "${ARTIFACT_DIR}/quay-subscription.yaml" || true
    oc -n "${QUAYNAMESPACE}" get csv -o yaml > "${ARTIFACT_DIR}/quay-csvs.yaml" || true
    oc get crd | grep -E 'NAME|quay' > "${ARTIFACT_DIR}/quay-crds.txt" || true
    oc -n "${QUAYNAMESPACE}" get pods -o wide > "${ARTIFACT_DIR}/quay-operator-pods.txt" || true
fi

echo "Quay Operator is deployed successfully"


