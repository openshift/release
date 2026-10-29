#!/bin/bash
set -o errexit
set -o nounset
set -o pipefail
set -x

SERVICE_MESH=${SERVICE_MESH}
WAYPOINT=${WAYPOINT:-false}

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
if [[ ${SERVICE_MESH} == "sidecar" ]]; then
  echo "Adding istio-injection=enabled label to ns"
  oc label ns netperf istio-injection=enabled --overwrite
elif [[ ${SERVICE_MESH} == "ambient" ]]; then
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
  echo "No known SERVICE_MESH defined (sidecar, ambient). Running with default CNI"
fi
oc create sa netperf -n netperf
oc adm policy add-scc-to-user hostnetwork -z netperf -n netperf

# Install the Istio Ingress Gateway on an Infra node, isolated from openshift-ingress (haproxy pods)
oc apply -f - <<EOF
apiVersion: apps/v1
kind: Deployment
metadata:
  name: istio-ingressgateway
  namespace: istio-system
spec:
  replicas: 1
  selector:
    matchLabels:
      istio: ingressgateway
  template:
    metadata:
      annotations:
        inject.istio.io/templates: gateway 
      labels:
        istio: ingressgateway
        sidecar.istio.io/inject: "true"
    spec:
      containers:
        - name: istio-proxy
          image: auto 
          securityContext:
            capabilities:
              drop:
              - ALL
            allowPrivilegeEscalation: false
            privileged: false
            readOnlyRootFilesystem: true
            runAsNonRoot: true
          ports:
          - containerPort: 15090
            protocol: TCP
            name: http-envoy-prom
          resources:
            limits:
              memory: 2Gi
            requests:
              cpu: 100m
              memory: 2Gi
      securityContext:
        sysctls:
        - name: net.ipv4.ip_unprivileged_port_start
          value: "0"
      nodeSelector:
        node-role.kubernetes.io/infra: ""
      tolerations:
        - effect: NoSchedule
          key: node-role.kubernetes.io/infra
          operator: Exists
        - effect: NoExecute
          key: node-role.kubernetes.io/infra
          operator: Exists
      affinity:
        nodeAffinity:
          requiredDuringSchedulingIgnoredDuringExecution:
            nodeSelectorTerms:
            - matchExpressions:
              - key: node-role.kubernetes.io/infra
                operator: Exists
        podAntiAffinity:
          requiredDuringSchedulingIgnoredDuringExecution:
          - labelSelector:
              matchLabels:
                ingresscontroller.operator.openshift.io/deployment-ingresscontroller: default
            topologyKey: kubernetes.io/hostname
            namespaceSelector:
              matchLabels:
                kubernetes.io/metadata.name: openshift-ingress
EOF

oc wait deployment istio-ingressgateway -n istio-system --for=condition=Available=True --timeout=300s

# Create the Service
oc apply -f - <<EOF
apiVersion: v1
kind: Service
metadata:
  name: istio-ingressgateway
  namespace: istio-system
spec:
  type: ClusterIP 
  selector:
    istio: ingressgateway
  ports:
    - name: status-port
      port: 15021
      protocol: TCP
      targetPort: 15021
    - name: http2
      port: 80
      protocol: TCP
      targetPort: 80
    - name: https
      port: 443
      protocol: TCP
      targetPort: 443
EOF

# Debug output for the gateway
oc get pods -n istio-system
oc get services -n istio-system

echo "Gateway deployed successfully. Mesh configuration completed"
