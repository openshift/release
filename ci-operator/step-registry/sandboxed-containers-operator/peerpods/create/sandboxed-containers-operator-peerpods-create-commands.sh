#!/bin/bash

set -euo pipefail

if test -s "${SHARED_DIR}/proxy-conf.sh"; then
    # shellcheck disable=SC1090
    source "${SHARED_DIR}/proxy-conf.sh"
fi

PEERPOD_NAMESPACE="${PEERPOD_NAMESPACE:-openshift-sandboxed-containers-operator}"
PEERPOD_NAME="${PEERPOD_NAME:-tls-scan-peerpod}"

cat <<EOF | oc apply -f -
apiVersion: v1
kind: Pod
metadata:
  name: ${PEERPOD_NAME}
  namespace: ${PEERPOD_NAMESPACE}
spec:
  runtimeClassName: kata-remote
  automountServiceAccountToken: false
  containers:
    - name: pause
      image: registry.access.redhat.com/ubi9/ubi-minimal:latest
      command: ["sleep", "infinity"]
      resources:
        requests:
          cpu: 10m
          memory: 32Mi
        limits:
          cpu: 100m
          memory: 64Mi
      securityContext:
        runAsNonRoot: true
        runAsUser: 1000
        readOnlyRootFilesystem: true
        allowPrivilegeEscalation: false
        capabilities:
          drop:
            - ALL
EOF

echo "Waiting for peer pod ${PEERPOD_NAME} to be ready..."
oc wait "pod/${PEERPOD_NAME}" -n "${PEERPOD_NAMESPACE}" --for=condition=Ready --timeout=10m
echo "Peer pod ${PEERPOD_NAME} is ready"
