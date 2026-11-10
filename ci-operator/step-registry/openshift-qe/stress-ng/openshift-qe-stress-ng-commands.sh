#!/bin/bash
set -o errexit
set -o nounset
set -o pipefail
set -x

# Set command line arguments
ARGS=()
if [[ -n "$STRESS_NG_CPU_CORES" && "$STRESS_NG_CPU_CORES" -ne 0 ]]; then
  ARGS+=("--cpu" "$STRESS_NG_CPU_CORES")
fi
if [[ -n "$STRESS_NG_CPU_LOAD" && "$STRESS_NG_CPU_LOAD" -ne 0 ]]; then
  ARGS+=("--cpu-load" "$STRESS_NG_CPU_LOAD")
fi

# Apply the DaemonSet
oc apply -f - <<EOF
apiVersion: apps/v1
kind: DaemonSet
metadata:
  name: $STRESS_NG_NAME
  namespace: $STRESS_NG_NAMESPACE
  labels:
    k8s-app: stress
spec:
  selector:
    matchLabels:
      name: $STRESS_NG_NAME
  template:
    metadata:
      labels:
        name: $STRESS_NG_NAME
    spec:
      tolerations:
        - key: node-role.kubernetes.io/control-plane
          operator: Exists
          effect: NoSchedule
        - key: node-role.kubernetes.io/master
          operator: Exists
          effect: NoSchedule
      containers:
        - name: stress
          image: $STRESS_NG_IMAGE
          command: ["stress-ng"]
          args: [${ARGS[@]}]
EOF
