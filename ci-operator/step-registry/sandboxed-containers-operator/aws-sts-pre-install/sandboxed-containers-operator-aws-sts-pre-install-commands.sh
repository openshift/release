#!/bin/bash

# Pre-create the OSC operator subscription with ROLEARN in spec.config.env so
# OLM injects it into the controller-manager pod. The test's
# ensureOperatorIsSubscribed skips subscription creation when one already
# exists, preserving the ROLEARN injection needed for the STS credential flow.

ROLE_ARN=$(cat "${SHARED_DIR}/osc-irsa-role-arn")
NS="openshift-sandboxed-containers-operator"

echo "AWS STS mode: pre-creating subscription with ROLEARN=${ROLE_ARN}"

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
    - name: ROLEARN
      value: "${ROLE_ARN}"
EOF
