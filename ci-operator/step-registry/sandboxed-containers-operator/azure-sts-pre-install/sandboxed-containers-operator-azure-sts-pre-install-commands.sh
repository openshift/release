#!/bin/bash

# Pre-create the OSC operator subscription with CLIENTID, TENANTID, and SUBSCRIPTIONID
# in spec.config.env so OLM injects them into the controller-manager pod. The test's
# ensureOperatorIsSubscribed skips subscription creation when one already exists,
# preserving the identity env vars needed for the Azure STS credential flow.

NS="openshift-sandboxed-containers-operator"

CLIENT_ID=$(oc get configmap osc-identity -n default -o jsonpath='{.data.clientId}')
TENANT_ID=$(oc get configmap osc-identity -n default -o jsonpath='{.data.tenantId}')
SUBSCRIPTION_ID=$(oc get configmap osc-identity -n default -o jsonpath='{.data.subscriptionId}')

if [[ -z "${CLIENT_ID}" || -z "${TENANT_ID}" || -z "${SUBSCRIPTION_ID}" ]]; then
    echo "ERROR: osc-identity configmap is missing required fields"
    echo "  clientId: ${CLIENT_ID}"
    echo "  tenantId: ${TENANT_ID}"
    echo "  subscriptionId: ${SUBSCRIPTION_ID}"
    exit 1
fi

echo "Azure STS mode: pre-creating subscription with CLIENTID=${CLIENT_ID}"

oc create namespace "${NS}" --dry-run=client -o yaml | oc apply -f -

oc apply -f - <<EOF
apiVersion: operators.coreos.com/v1
kind: OperatorGroup
metadata:
  name: sandboxed-containers-operator-group
  namespace: ${NS}
spec:
  targetNamespaces:
  - ${NS}
---
apiVersion: operators.coreos.com/v1alpha1
kind: Subscription
metadata:
  name: sandboxed-containers-operator
  namespace: ${NS}
spec:
  channel: "${OPERATOR_UPDATE_CHANNEL:-stable}"
  installPlanApproval: Automatic
  name: sandboxed-containers-operator
  source: "${CATALOG_SOURCE_NAME:-redhat-operators}"
  sourceNamespace: openshift-marketplace
  config:
    env:
    - name: CLIENTID
      value: "${CLIENT_ID}"
    - name: TENANTID
      value: "${TENANT_ID}"
    - name: SUBSCRIPTIONID
      value: "${SUBSCRIPTION_ID}"
EOF
