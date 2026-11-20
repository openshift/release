#!/bin/bash
set -euo pipefail

echo "Deploying persistent ClusterAutoscaler and MachineAutoscalers..."

# Get worker MachineSets
MACHINESETS=$(oc get machinesets -n openshift-machine-api -o jsonpath='{.items[*].metadata.name}' | tr ' ' '\n' | grep worker)

if [ -z "$MACHINESETS" ]; then
    echo "ERROR: No worker MachineSets found"
    exit 1
fi

MACHINESET_COUNT=$(echo "$MACHINESETS" | wc -l)
echo "Found $MACHINESET_COUNT worker MachineSets"

# Create ClusterAutoscaler
cat <<EOF | oc apply -f -
apiVersion: autoscaling.openshift.io/v1
kind: ClusterAutoscaler
metadata:
  name: default
spec:
  podPriorityThreshold: -10
  resourceLimits:
    maxNodesTotal: 200
  scaleDown:
    enabled: true
    delayAfterAdd: 10m
    delayAfterDelete: 5m
    delayAfterFailure: 30s
    unneededTime: 5m
EOF
echo "Created ClusterAutoscaler: default"

# Create MachineAutoscaler for each worker MachineSet
for ms in $MACHINESETS; do
    cat <<EOF | oc apply -f -
apiVersion: autoscaling.openshift.io/v1beta1
kind: MachineAutoscaler
metadata:
  name: ${ms}
  namespace: openshift-machine-api
spec:
  minReplicas: ${AUTOSCALER_MIN_REPLICAS}
  maxReplicas: ${AUTOSCALER_MAX_REPLICAS}
  scaleTargetRef:
    apiVersion: machine.openshift.io/v1beta1
    kind: MachineSet
    name: ${ms}
EOF
    echo "Created MachineAutoscaler: ${ms} (min=${AUTOSCALER_MIN_REPLICAS}, max=${AUTOSCALER_MAX_REPLICAS})"
done

echo "Autoscaler deployment complete. Resources will persist for subsequent steps."
echo "Total max capacity: $((MACHINESET_COUNT * AUTOSCALER_MAX_REPLICAS)) workers across $MACHINESET_COUNT AZs"
