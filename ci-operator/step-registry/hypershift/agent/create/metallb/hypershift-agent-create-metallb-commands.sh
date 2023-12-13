#!/bin/bash

set -o nounset
set -o errexit
set -o pipefail
set -x

export KUBECONFIG=${SHARED_DIR}/nested_kubeconfig
if [ -f "${SHARED_DIR}/proxy-conf.sh" ] ; then
  source "${SHARED_DIR}/proxy-conf.sh"
fi

echo "install metallb operator"
# create the install namespace
oc apply -f - <<EOF
apiVersion: v1
kind: Namespace
metadata:
  name: metallb-system
  labels:
    openshift.io/cluster-monitoring: "true"
EOF

# deploy new operator group
oc apply -f - <<EOF
apiVersion: operators.coreos.com/v1
kind: OperatorGroup
metadata:
  name: metallb-system
  namespace: metallb-system
spec: {}
EOF

# subscribe to the operator
cat <<EOF | oc apply -f -
apiVersion: operators.coreos.com/v1alpha1
kind: Subscription
metadata:
  name: metallb-operator
  namespace: metallb-system
spec:
  channel: stable
  installPlanApproval: Automatic
  name: metallb-operator
  source: "${METALLB_OPERATOR_SUB_SOURCE}"
  sourceNamespace: openshift-marketplace
EOF

RETRIES=30
CSV=
for i in $(seq "${RETRIES}") max; do
  [[ "${i}" == "max" ]] && break
  sleep 30
  if [[ -z "${CSV}" ]]; then
    echo "[Retry ${i}/${RETRIES}] The subscription is not yet available. Trying to get it..."
    CSV=$(oc get subscription -n metallb-system metallb-operator -o jsonpath='{.status.installedCSV}')
    continue
  fi

  if [[ $(oc get csv -n metallb-system ${CSV} -o jsonpath='{.status.phase}') == "Succeeded" ]]; then
    echo "metallb-operator is deployed"
    break
  fi
  echo "Try ${i}/${RETRIES}: metallb-operator is not deployed yet. Checking again in 30 seconds"
done

if [[ "$i" == "max" ]]; then
  echo "Error: Failed to deploy metallb-operator"
  echo "csv ${CSV} YAML"
  oc get csv "${CSV}" -n metallb-system -o yaml
  echo
  echo "csv ${CSV} Describe"
  oc describe csv "${CSV}" -n metallb-system
  exit 1
fi
echo "successfully installed metallb-operator"

oc create -f - <<EOF
apiVersion: metallb.io/v1beta1
kind: MetalLB
metadata:
  name: metallb
  namespace: metallb-system
EOF

echo "Configure IPAddressPool in different network environments separately."
if [[ $IP_STACK == "v4" ]]; then
  oc create -f - <<EOF
apiVersion: metallb.io/v1beta1
kind: IPAddressPool
metadata:
  name: ingress-public-ip
  namespace: metallb-system
spec:
  protocol: layer2
  autoAssign: false
  addresses:
  - 192.168.111.30-192.168.111.30
EOF
elif [[ $IP_STACK == "v4v6" ]]; then
  oc create -f - <<EOF
apiVersion: metallb.io/v1beta1
kind: IPAddressPool
metadata:
  name: ingress-public-ip
  namespace: metallb-system
spec:
  protocol: layer2
  autoAssign: false
  addresses:
  - 192.168.111.30-192.168.111.30
  - fd2e:6f44:5dd8:c956::1e-fd2e:6f44:5dd8:c956::1e
EOF
else
  echo "$IP_STACK don't support"
  exit 1
fi

oc create -f - <<EOF
apiVersion: metallb.io/v1beta1
kind: BGPAdvertisement
metadata:
  name: ingress-public-ip
  namespace: metallb-system
spec:
  aggregationLength: 32
  aggregationLengthV6: 128
EOF

oc create -f - <<EOF
kind: Service
apiVersion: v1
metadata:
  annotations:
    metallb.universe.tf/address-pool: ingress-public-ip
  name: metallb-ingress
  namespace: openshift-ingress
spec:
  ports:
    - name: http
      protocol: TCP
      port: 80
      targetPort: 80
    - name: https
      protocol: TCP
      port: 443
      targetPort: 443
  selector:
    ingresscontroller.operator.openshift.io/deployment-ingresscontroller: default
  type: LoadBalancer
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
