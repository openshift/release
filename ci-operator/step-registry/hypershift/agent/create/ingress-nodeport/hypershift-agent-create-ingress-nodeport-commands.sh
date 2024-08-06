#!/bin/bash

set -o nounset
set -o errexit
set -o pipefail
set -x

if [ -f "${SHARED_DIR}/proxy-conf.sh" ] ; then
  source "${SHARED_DIR}/proxy-conf.sh"
fi

export KUBECONFIG=${SHARED_DIR}/nested_kubeconfig

oc create -f - <<EOF
kind: Service
apiVersion: v1
metadata:
  name: ingress-nodeport
  namespace: openshift-ingress
spec:
  ports:
    - name: http
      protocol: TCP
      port: 80
      targetPort: 80
      nodePort: 30080
    - name: https
      protocol: TCP
      port: 443
      targetPort: 443
      nodePort: 30443
  selector:
    ingresscontroller.operator.openshift.io/deployment-ingresscontroller: default
  type: NodePort
EOF

echo "[WARN] Wait HostedCluster ready..."
for i in {1..60} max; do
  if [[ $i == "max" ]]; then
    echo "[ERROR] The HostedCluster COs are not ready yet after 30mins. Exiting..."
    exit 1
  fi
  if oc wait --timeout=30s clusterversion/version --for='condition=Available=True'; then
    echo "[INFO]$(date --rfc-3339=seconds): The HostedCluster COs are ready"
    break
  fi
  echo "[WARN]$(date --rfc-3339=seconds): The HostedCluster COs are not ready yet. Retrying..."
  oc get clusterversion || true
done

export KUBECONFIG=${SHARED_DIR}/kubeconfig
HOSTED_CLUSTER_NAME="$(<"${SHARED_DIR}/hostedcluster_name")"
echo "Waiting for ManagedCluster to be ready"

for i in {1..60} max; do
  if [[ $i == "max" ]]; then
    echo "[ERROR]$(date --rfc-3339=seconds): The ManagedCluster is not ready yet after 30mins. Exiting..."
    exit 1
  fi
  if oc wait managedcluster "${HOSTED_CLUSTER_NAME}" --for='condition=ManagedClusterJoined' --timeout=1s && \
     oc wait managedcluster "${HOSTED_CLUSTER_NAME}" --for='condition=ManagedClusterConditionAvailable' --timeout=1s && \
     oc wait managedcluster "${HOSTED_CLUSTER_NAME}" --for='condition=HubAcceptedManagedCluster' --timeout=1s; then
    echo "[INFO]$(date --rfc-3339=seconds): ManagedCluster is ready"
    break
  fi
  echo "[WARN]$(date --rfc-3339=seconds): ManagedCluster not yet ready"
  sleep 30s
done

echo "ManagedCluster is ready and the ingress is exposed."
