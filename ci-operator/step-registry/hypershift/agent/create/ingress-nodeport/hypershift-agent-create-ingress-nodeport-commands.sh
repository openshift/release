#!/bin/bash

set -o nounset
set -o errexit
set -o pipefail
set -x

export KUBECONFIG=${SHARED_DIR}/nested_kubeconfig
if [ -f "${SHARED_DIR}/proxy-conf.sh" ] ; then
  source "${SHARED_DIR}/proxy-conf.sh"
fi

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

echo "Wait HostedCluster ready..."
until \
  oc wait clusterversion/version --for='condition=Available=True' > /dev/null; do
    echo "$(date --rfc-3339=seconds) Clusteroperators not yet ready"
    oc get clusterversion 2>/dev/null || true
    sleep 1s
done

export KUBECONFIG=${SHARED_DIR}/kubeconfig
HOSTED_CLUSTER_NS=$(oc get hostedcluster -A -ojsonpath='{.items[0].metadata.namespace}')
if [[ $HOSTED_CLUSTER_NS == "local-cluster" ]]; then
  echo "Waiting for ManagedCluster to be ready"
  export KUBECONFIG=${SHARED_DIR}/kubeconfig
  CLUSTER_NAME="$(echo -n $PROW_JOB_ID|sha256sum|cut -c-20)"
  until \
  oc wait managedcluster ${CLUSTER_NAME} --for='condition=ManagedClusterJoined' >/dev/null && \
  oc wait managedcluster ${CLUSTER_NAME} --for='condition=ManagedClusterConditionAvailable' >/dev/null && \
  oc wait managedcluster ${CLUSTER_NAME} --for='condition=HubAcceptedManagedCluster' >/dev/null;  do
  echo "$(date --rfc-3339=seconds) ManagedCluster not yet ready"
  sleep 10s
  done
fi
