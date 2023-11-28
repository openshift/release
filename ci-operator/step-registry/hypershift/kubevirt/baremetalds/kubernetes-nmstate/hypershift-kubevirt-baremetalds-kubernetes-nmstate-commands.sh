#!/bin/bash

set -o nounset
set -o errexit
set -o pipefail
set -x

HANDLER_NAMESPACE=openshift-nmstate

cat << EOF | oc apply -f -
apiVersion: nmstate.io/v1
kind: NMState
metadata:
  name: nmstate
EOF

# Wait a little for resources to be created
sleep 5

oc rollout status -w -n ${HANDLER_NAMESPACE} ds nmstate-handler --timeout=2m
oc rollout status -w -n ${HANDLER_NAMESPACE} deployment nmstate-webhook --timeout=2m
