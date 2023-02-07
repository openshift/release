#!/bin/bash

set -o nounset
set -o errexit
set -o pipefail

# Get the cluster URL from the shared directory
CLUSTER_URL=$(cat ${SHARED_DIR}/cluster_url)

echo "Creating MTR HTTP ingress"
oc apply -f - <<EOF
apiVersion: networking.k8s.io/v1
kind: Ingress
metadata:
  name: mtr-ingress
  namespace: mtr
  labels:
    app: mtr
spec:
  rules:
    - host: mtr-mtr.${CLUSTER_URL}
      http:
        paths:
          - path: /
            pathType: Prefix
            backend:
              service:
                name: mtr
                port:
                  name: web-port
EOF


echo "Adding network policy for MTR HTTP ingress..."
oc apply -f - <<EOF
apiVersion: networking.k8s.io/v1
kind: NetworkPolicy
metadata:
  name: mtr
  namespace: mtr
spec:
  podSelector:
    matchLabels:
      app: mtr
  policyTypes:
    - Ingress
  ingress:
    - {}