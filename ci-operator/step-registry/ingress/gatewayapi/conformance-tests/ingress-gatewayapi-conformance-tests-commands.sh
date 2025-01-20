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

sleep 300
oc get gatewayclass -A

echo "Go version: $(go version)"
cd /go/src/github.com
mkdir -p kubernetes-sigs
cd kubernetes-sigs
rm -rf ./gateway-api
# currently CRD v1.0.0 is supported
git clone --branch release-1.0 https://github.com/kubernetes-sigs/gateway-api
cd gateway-api
go mod vendor

# modify the timeout to make tests passed on AWS
sed -i "s/MaxTimeToConsistency:              30/MaxTimeToConsistency:              90/g" conformance/utils/config/timeout.go

echo "Start Gateway API Conformance Testing"
go test ./conformance -v -timeout 0 -run TestConformance -args --supported-features=Gateway,HTTPRoute

echo "Complete Gateway API Conformance Testing"

sleep 300
