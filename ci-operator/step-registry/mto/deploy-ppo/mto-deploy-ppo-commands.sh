#!/bin/bash

set -o nounset
set -o errexit
set -o pipefail

# Deploy Multiarch Tuning Operator
# Now  we deploy it using the latest bundle images in registry.ci,
# and will change to via operatorhub when it's ready.
NAMESPACE=openshift-multiarch-tuning-operator
OOBUNDLE=registry.ci.openshift.org/origin/multiarch-tuning-op-bundle:main
operator-sdk run bundle $OOBUNDLE -n $NAMESPACE
oc wait deployments -n ${NAMESPACE} \
  -l app.kubernetes.io/part-of=multiarch-tuning-operator \
  --for=condition=Available=True
oc wait pods -n ${NAMESPACE} \
  -l control-plane=controller-manager \
  --for=condition=Ready=True

# Deploy Pod Placement operand
oc create -f - <<EOF
kind: PodPlacementConfig
apiVersion: multiarch.openshift.io/v1alpha1
spec:
  logVerbosity: Normal
metadata:
  name: cluster
EOF
oc wait pods -n ${NAMESPACE} \
  -l controller=pod-placement-controller \
  --for=condition=Ready=True
oc wait pods -n ${NAMESPACE} \
  -l controller=pod-placement-web-hook \
  --for=condition=Ready=True
