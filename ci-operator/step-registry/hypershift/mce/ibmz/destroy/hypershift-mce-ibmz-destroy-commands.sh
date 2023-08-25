
# Hosted Control Plane parameters
CLUSTERS_NAMESPACE="clusters"
HOSTED_CLUSTER_NAME="agent-cluster"
export HOSTED_CLUSTER_NAME
export HOSTED_CONTROL_PLANE_NAMESPACE="${CLUSTERS_NAMESPACE}-${HOSTED_CLUSTER_NAME}"

# Scale down the nodepool 
oc -n ${CLUSTERS_NAMESPACE} scale nodepool ${HOSTED_CLUSTER_NAME} --replicas 0

# Wait for compute nodes to detach
for ((i=1; i<=20; i++)); do
  node_count=$(oc get no --kubeconfig=${SHARED_DIR}/guest_kubeconfig --no-headers | wc -l)
if [ "$node_count" -eq 0 ]; then
  echo "Compute nodes detached"
  break
else
  echo "Waiting for Compute nodes to detach"
fi
sleep 20
done

