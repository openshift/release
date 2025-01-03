#!/bin/bash

set -o nounset
set -o errexit
set -o pipefail

echo "Creat GatewayClass gateway-conformance"
oc create -f -<<EOF
apiVersion: gateway.networking.k8s.io/v1
kind: GatewayClass
metadata:
  name: gateway-conformance
spec:
  controllerName: openshift.io/gateway-controller
EOF

oc wait --for=condition=Accepted=true gatewayclass/gateway-conformance --timeout=300s

echo "All gatewayclass ststus"
oc get gatewayclass -A
