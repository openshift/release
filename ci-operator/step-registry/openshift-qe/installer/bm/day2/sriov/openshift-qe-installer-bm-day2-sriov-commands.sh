#!/bin/bash
set -o errexit
set -o nounset
set -o pipefail
set -x
cat /etc/os-release

if [ ${BAREMETAL} == "true" ]; then
  SSH_ARGS="-i /bm/jh_priv_ssh_key -oStrictHostKeyChecking=no -oUserKnownHostsFile=/dev/null"
  bastion="$(cat /bm/address)"
  # Copy over the kubeconfig
  if [ ! -f "${SHARED_DIR}/kubeconfig" ]; then
    ssh ${SSH_ARGS} root@$bastion "cat ${KUBECONFIG_PATH}" > /tmp/kubeconfig
    export KUBECONFIG=/tmp/kubeconfig
  else
    export KUBECONFIG=${SHARED_DIR}/kubeconfig
  fi
  # Setup socks proxy
  ssh ${SSH_ARGS} root@$bastion -fNT -D 12345
  export https_proxy=socks5://localhost:12345
  export http_proxy=socks5://localhost:12345
  oc --kubeconfig="$KUBECONFIG" config set-cluster bm --proxy-url=socks5://localhost:12345
fi

oc config view
oc projects

# Install the SRIOV operator
cat << EOF| oc apply -f -
apiVersion: v1
kind: Namespace
metadata:
  name: openshift-sriov-network-operator
  annotations:
    workload.openshift.io/allowed: management
EOF

cat << EOF| oc apply -f -
apiVersion: operators.coreos.com/v1
kind: OperatorGroup
metadata:
  name: sriov-network-operators
  namespace: openshift-sriov-network-operator
spec:
  targetNamespaces:
  - openshift-sriov-network-operator
EOF

cat << EOF| oc apply -f -
apiVersion: operators.coreos.com/v1alpha1
kind: Subscription
metadata:
  name: sriov-network-operator-subscription
  namespace: openshift-sriov-network-operator
spec:
  channel: stable
  name: sriov-network-operator
  source: redhat-operators
  sourceNamespace: openshift-marketplace
EOF

# Wait for the operator to be ready
until [ "$(kubectl get csv -n openshift-sriov-network-operator | grep sriov-network-operator > /dev/null; echo $?)" == 0 ];
  do echo "Waiting for SRIOV operator"
  sleep 5
done
kubectl wait --for jsonpath='{.status.phase}'=Succeeded --timeout=10m -n openshift-sriov-network-operator "$(kubectl get csv -n openshift-sriov-network-operator -oname)"
sleep 60

{
cat << EOF| oc apply -f -
apiVersion: sriovnetwork.openshift.io/v1
kind: SriovOperatorConfig
metadata:
  name: default
  namespace: openshift-sriov-network-operator
spec:
  disableDrain: false
  enableInjector: true
  enableOperatorWebhook: true
  logLevel: 2
EOF
} || echo Failed to apply SriovOperatorConfig

sleep 180

# Create the SRIOV network policy
cat << EOF| oc apply -f -
apiVersion: sriovnetwork.openshift.io/v1
kind: SriovNetworkNodePolicy
metadata:
  name: ${SRIOV_POLICY_NAME}
  namespace: openshift-sriov-network-operator
spec:
  deviceType: ${SRIOV_DEVICE_TYPE}
  nicSelector:
    pfNames:
     - ${SRIOV_PF_NAME}
  mtu: ${SRIOV_MTU}
  nodeSelector:
    ${SRIOV_NODE_SELECTOR}: ""
  numVfs: ${SRIOV_NUM_VFS}
  resourceName: ${SRIOV_RESOURCE_NAME}
EOF

if [ ${BAREMETAL} == "true" ]; then
  # kill the ssh tunnel so the job completes
  pkill ssh
fi
