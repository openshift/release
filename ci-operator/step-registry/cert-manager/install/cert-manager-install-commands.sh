#!/bin/bash

set -e
set -u
set -o pipefail

timestamp() {
    date -u --rfc-3339=seconds
}

if [ -f "${SHARED_DIR}/proxy-conf.sh" ] ; then
    source "${SHARED_DIR}/proxy-conf.sh"
    echo "proxy: ${SHARED_DIR}/proxy-conf.sh"
fi

# Check if the catalogsource is ready to use
if [[ ! "$(oc get catalogsource $INSTALL_CATSRC -n openshift-marketplace -o=jsonpath='{.status.connectionState.lastObservedState}')" == "READY" ]]; then
    echo "The CatalogSource '$INSTALL_CATSRC' status is not ready"
    exit 1
fi

# Define common variables
SUB="openshift-cert-manager-operator"
OPERATOR_NAMESPACE="cert-manager-operator"
OPERAND_NAMESPACE="cert-manager"
INTERVAL=10

# Prepare the operator installation manifests

echo "# Creating the Namespace, OperatorGroup and Subscription for the operator installation."
MANIFEST=$(cat <<EOF
apiVersion: v1
kind: Namespace
metadata:
  name: $OPERATOR_NAMESPACE
---
apiVersion: operators.coreos.com/v1
kind: OperatorGroup
metadata:
  name: cert-manager-operator-og
  namespace: $OPERATOR_NAMESPACE
spec:
  targetNamespaces:
  - $OPERATOR_NAMESPACE
---
apiVersion: operators.coreos.com/v1alpha1
kind: Subscription
metadata:
  name: $SUB
  namespace: $OPERATOR_NAMESPACE
spec:
  source: $INSTALL_CATSRC
  sourceNamespace: openshift-marketplace
  name: openshift-cert-manager-operator
  channel: "$INSTALL_CHANNEL"
  installPlanApproval: Manual
EOF
)

# Set the startingCSV to the 'INSTALL_CSV' if 'INSTALL_CSV' is not empty
if [ -n "${INSTALL_CSV}" ]; then
    MANIFEST="${MANIFEST}"$'\n'"  startingCSV: ${INSTALL_CSV}"
fi

oc create -f - <<< "${MANIFEST}"

echo "# Waiting for the installPlan to show up, then approving it."
MAX_RETRY=30
COUNTER=0
while :;
do
    INSTALL_PLAN=$(oc get subscription $SUB -n $OPERATOR_NAMESPACE -o=jsonpath='{.status.installplan.name}' || true)
    echo "Checking installPlan for subscription $SUB the #${COUNTER}-th time ..."
    if [[ -n "$INSTALL_PLAN" ]]; then
        oc patch installplan "${INSTALL_PLAN}" -n $OPERATOR_NAMESPACE --type merge --patch '{"spec":{"approved":true}}'
        echo "[$(timestamp)] The installPlan $INSTALL_PLAN is approved"
        break
    fi
    ((++COUNTER))
    if [[ $COUNTER -eq $MAX_RETRY ]]; then
        echo "[$(timestamp)] The installPlan for subscription $SUB didn't show up after $((MAX_RETRY * INTERVAL)) seconds. Dumping status:"
        oc get subscription $SUB -n $OPERATOR_NAMESPACE -o=jsonpath='{.status}'
        exit 1
    fi
    sleep $INTERVAL
done

echo "# Waiting for the CSV status to be ready."
MAX_RETRY=30
COUNTER=0
while :;
do
    CSV=$(oc get installplan $INSTALL_PLAN -n $OPERATOR_NAMESPACE -o=jsonpath='{.spec.clusterServiceVersionNames[0]}' || true)
    echo "Checking CSV $CSV status for the #${COUNTER}-th time ..."
    if [[ "$(oc get csv "$CSV" -n $OPERATOR_NAMESPACE -o jsonpath='{.status.phase}')" == "Succeeded" ]]; then
        echo "[$(timestamp)] The CSV $CSV status becomes ready"
        break
    fi
    ((++COUNTER))
    if [[ $COUNTER -eq $MAX_RETRY ]]; then
        echo "[$(timestamp)] The CSV $CSV status is not ready after $((MAX_RETRY * INTERVAL)) seconds. Dumping status:"
        oc get csv "$CSV" -n $OPERATOR_NAMESPACE -o=jsonpath='{.status}'
        oc get subscription $SUB -n $OPERATOR_NAMESPACE -o=jsonpath='{.status}'
        exit 1
    fi
    sleep $INTERVAL
done

echo "# Waiting for the operand pods status to be ready."
MAX_RETRY=30
COUNTER=0
while :;
do
    echo "Checking cert-manager pods status for the #${COUNTER}-th time ..."
    if [ "$(oc get pod -n $OPERAND_NAMESPACE -o=jsonpath='{.items[*].status.phase}')" == "Running Running Running" ]; then
        echo "[$(timestamp)] Finished the cert-manager operator installation. The operand are all ready."
        oc get pod -n $OPERAND_NAMESPACE
        break

    fi
    ((++COUNTER))
    if [[ $COUNTER -eq $MAX_RETRY ]]; then
        echo "[$(timestamp)] The cert-manager pods are not all ready after $((MAX_RETRY * INTERVAL)) seconds. Dumping status:"
        oc get pod -n $OPERAND_NAMESPACE
        exit 1
    fi
    sleep $INTERVAL
done
