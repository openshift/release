#!/bin/bash

set -e
set -u
set -o pipefail

if [ -f "${SHARED_DIR}/proxy-conf.sh" ] ; then
    source "${SHARED_DIR}/proxy-conf.sh"
    echo "proxy: ${SHARED_DIR}/proxy-conf.sh"
fi

CATSRC=qe-app-registry
if [[ ! "$(oc get catalogsource qe-app-registry -n openshift-marketplace -o yaml)" =~ "lastObservedState: READY" ]]; then
    echo "The catalogsource qe-app-registry is either not existing or not ready. Will use redhat-operators to install cert-manager Operator."
    CATSRC=redhat-operators
fi

oc create -f - << EOF
apiVersion: v1
kind: Namespace
metadata:
  name: cert-manager-operator
---
apiVersion: operators.coreos.com/v1
kind: OperatorGroup
metadata:
  name: cert-manager-operator-og
  namespace: cert-manager-operator
spec:
  targetNamespaces:
  - cert-manager-operator
---
apiVersion: operators.coreos.com/v1alpha1
kind: Subscription
metadata:
  name: openshift-cert-manager-operator
  namespace: cert-manager-operator
spec:
  channel: stable-v1
  installPlanApproval: Automatic
  name: openshift-cert-manager-operator
  source: "$CATSRC"
  sourceNamespace: openshift-marketplace
EOF

MAX_RETRY=20
INTERVAL=10
COUNTER=0
while :;
do
    echo "Checking openshift-cert-manager-operator subscription status for the #${COUNTER}-th time ..."
    if [ "$(oc get subscription openshift-cert-manager-operator -n cert-manager-operator -o=jsonpath='{.status.state}')" == AtLatestKnown ]; then
        echo "The openshift-cert-manager-operator subscription status becomes ready" && break
    fi
    ((++COUNTER))
    if [[ $COUNTER -eq $MAX_RETRY ]]; then
        echo "The openshift-cert-manager-operator subscription status is not ready after $((MAX_RETRY * INTERVAL)) seconds. Dumping status:"
        oc get subscription openshift-cert-manager-operator -n cert-manager-operator -o=jsonpath='{.status}'
        exit 1
    fi
    sleep $INTERVAL
done

MAX_RETRY=20
INTERVAL=10
COUNTER=0
while :;
do
    echo "Checking cert-manager-operator CSV status for the #${COUNTER}-th time ..."
    if [[ "$(oc get --no-headers csv -n cert-manager-operator)" == *cert-manager-operator.*Succeeded ]]; then
        echo "The cert-manager-operator CSV status becomes ready" && break
    fi
    ((++COUNTER))
    if [[ $COUNTER -eq $MAX_RETRY ]]; then
        echo "The cert-manager-operator CSV status is not ready after $((MAX_RETRY * INTERVAL)) seconds. Dumping status:"
        CSV_NAME=$(oc get csv -n cert-manager-operator | grep -E -o '^cert-manager-operator[^ ]*')
        oc get csv "$CSV_NAME" -n cert-manager-operator -o=jsonpath='{.status}'
        exit 1
    fi
    sleep $INTERVAL
done

MAX_RETRY=30
INTERVAL=10
COUNTER=0
while :;
do
    echo "Checking cert-manager pods status for the #${COUNTER}-th time ..."
    if [ "$(oc get pods -n cert-manager -o=jsonpath='{.items[*].status.phase}')" == "Running Running Running" ]; then
        echo "[$(date -u --rfc-3339=seconds)] Finished cert-manager Operator installation. The cert-manager pods are all ready."
        oc get po -n cert-manager
        break
    fi
    ((++COUNTER))
    if [[ $COUNTER -eq $MAX_RETRY ]]; then
        echo "The cert-manager pods are not all ready after $((MAX_RETRY * INTERVAL)) seconds. Dumping status:"
        oc get pods -n cert-manager
        exit 1
    fi
    sleep $INTERVAL
done
