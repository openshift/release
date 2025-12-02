#!/bin/bash
set -o errexit
set -o nounset
set -o pipefail
set -x

# Install the Istio Ingress Gateway
oc apply -f - <<EOF
apiVersion: apps/v1
kind: Deployment
metadata:
  name: istio-ingressgateway
  namespace: istio-system
spec:
  replicas: 2
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
              memory: 128Mi
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
