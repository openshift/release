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

# Create peer-pods-image-creation-secret with IRSA credentials for the podvm
# image builder job. The job mounts this secret via envFrom (after peer-pods-secret)
# to inject AWS_ROLE_ARN and AWS_WEB_IDENTITY_TOKEN_FILE for STS authentication.
# Using the secret (not aws-podvm-image-cm) allows the operator to create
# aws-podvm-image-cm from its own template, which provides all required defaults
# like INSTANCE_TYPE, AMI_VERSION, etc.
echo "Creating peer-pods-image-creation-secret with IRSA credentials for podvm image builder"
oc create secret generic peer-pods-image-creation-secret \
    --from-literal=AWS_ROLE_ARN="${ROLE_ARN}" \
    --from-literal=AWS_WEB_IDENTITY_TOKEN_FILE="/var/run/secrets/openshift/serviceaccount/token" \
    -n "${NS}"
