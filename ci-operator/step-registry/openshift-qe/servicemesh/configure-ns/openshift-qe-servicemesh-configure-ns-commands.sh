#!/bin/bash
set -o errexit
set -o nounset
set -o pipefail
set -x

MESH_MODE=${MESH_MODE}

# Ensure STRIC mTLS is enabled
oc apply -f - <<EOF
apiVersion: security.istio.io/v1
kind: PeerAuthentication
metadata:
  name: default
  namespace: istio-system 
spec:
  mtls:
    mode: STRICT
EOF

# Clean up any existing namespace
oc delete ns netperf --wait=true --ignore-not-found=true

# Create and configure the namespace for the workload
oc create ns netperf
if [[ ${MESH_MODE} == "sidecar" ]]; then
  echo "Adding istio-injection=enabled label to ns"
  oc label ns netperf istio-injection=enabled --overwrite
elif [[ ${MESH_MODE} == "ambient" ]]; then
  echo "Adding istio.io/dataplane-mode=ambient label to ns"
  oc label ns netperf istio.io/dataplane-mode=ambient --overwrite
  if [[ ${WAYPOINT} == "true" ]]; then
  oc apply -f - <<EOF
apiVersion: gateway.networking.k8s.io/v1
kind: Gateway
metadata:
  labels:
    istio.io/waypoint-for: service
  name: waypoint
  namespace: netperf
spec:
  gatewayClassName: istio-waypoint
  listeners:
  - name: mesh
    port: 15008
    protocol: HBONE
EOF
  oc wait gateway waypoint -n netperf --for=condition=Programmed=True --timeout=300s
  echo "Adding istio.io/use-waypoint=waypoint label to ns"
  oc label ns netperf istio.io/use-waypoint=waypoint --overwrite
  fi
else
  echo "No known MESH_MODE defined (sidecar, ambient). Running with default CNI"
fi
oc create sa netperf -n netperf
oc adm policy add-scc-to-user hostnetwork -z netperf -n netperf
