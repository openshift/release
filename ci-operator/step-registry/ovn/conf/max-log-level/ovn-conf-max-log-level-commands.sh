#!/bin/bash
set -o errexit
set -o nounset
set -o pipefail


NAMESPACE="openshift-ovn-kubernetes"
CONFIGMAP_NAME="env-overrides"

# Get all node names
NODE_NAMES=$(oc get nodes -o jsonpath='{range .items[*]}{.metadata.name}{"\n"}{end}')

# Construct the configmap YAML on the fly
CM_YAML=$(cat <<EOF
apiVersion: v1
kind: ConfigMap
metadata:
  name: ${CONFIGMAP_NAME}
  namespace: ${NAMESPACE}
data:
EOF
)

for NODE in ${NODE_NAMES}; do
  CM_YAML="${CM_YAML}
  ${NODE}: |
    OVN_KUBE_LOG_LEVEL=5
    OVN_LOG_LEVEL=dbg
"
done

CM_YAML="${CM_YAML}
  _master: |
    OVN_KUBE_LOG_LEVEL=5
    OVN_LOG_LEVEL=dbg
"

# Apply the configmap
echo "${CM_YAML}" | oc apply -f -

echo "ConfigMap '${CONFIGMAP_NAME}' applied to namespace '${NAMESPACE}'."

# Rollout restart the daemonset and deployment
oc -n ${NAMESPACE} rollout restart ds/ovnkube-node
oc -n ${NAMESPACE} rollout restart deployment/ovnkube-control-plane

echo "Rollout restart of ovnkube-node and ovnkube-control-plane triggered."

# Wait for rollouts to complete with a timeout
echo "Waiting for rollout of daemonset ovnkube-node to complete..."
oc -n ${NAMESPACE} rollout status ds/ovnkube-node --timeout=300s

echo "Waiting for rollout of deployment ovnkube-control-plane to complete..."
oc -n ${NAMESPACE} rollout status deployment/ovnkube-control-plane --timeout=300s

echo "Both ovnkube-node and ovnkube-control-plane rolled out successfully."

# Check actual process log levels in running containers
echo "Verifying actual process log levels..."

# Check ovnkube-cluster-manager in ovnkube-control-plane pods
echo "Checking ovnkube-cluster-manager log level in ovnkube-control-plane pods..."
for POD in $(oc -n ${NAMESPACE} get pods -l app=ovnkube-control-plane -o jsonpath='{.items[*].metadata.name}'); do
  echo "  Pod: ${POD}"
  if oc exec -n ${NAMESPACE} ${POD} -c ovnkube-cluster-manager -- pgrep -a -f init-cluster-manager 2>/dev/null | grep -i -- "--loglevel 5"; then
    echo "    ovnkube-cluster-manager: --loglevel 5 FOUND"
  else
    echo "    ovnkube-cluster-manager: --loglevel 5 NOT FOUND"
  fi
done

# Check ovnkube-controller in ovnkube-node pods
echo "Checking ovnkube-controller log level in ovnkube-node pods..."
for POD in $(oc -n ${NAMESPACE} get pods -l app=ovnkube-node -o jsonpath='{.items[*].metadata.name}'); do
  echo "  Pod: ${POD}"
  if oc exec -n ${NAMESPACE} ${POD} -c ovnkube-controller -- pgrep -a -f init-ovnkube-controller 2>/dev/null | grep -i -- "--loglevel 5"; then
    echo "    ovnkube-controller: --loglevel 5 FOUND"
  else
    echo "    ovnkube-controller: --loglevel 5 NOT FOUND"
  fi
done

# Check ovn-controller debug level in ovnkube-node pods
echo "Checking ovn-controller debug level in ovnkube-node pods..."
for POD in $(oc -n ${NAMESPACE} get pods -l app=ovnkube-node -o jsonpath='{.items[*].metadata.name}'); do
  echo "  Pod: ${POD}"
  if oc exec -n ${NAMESPACE} ${POD} -c ovn-controller -- pgrep -a -f ovn-controller 2>/dev/null | grep -i -- -vconsole:dbg; then
    echo "    ovn-controller: DEBUG ENABLED"
  else
    echo "    ovn-controller: DEBUG NOT ENABLED"
  fi
done

echo "Process log level verification complete."
