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

# Install the MetalLB operator
cat << EOF| oc apply -f -
apiVersion: v1
kind: Namespace
metadata:
  name: metallb-system
  labels:
    openshift.io/cluster-monitoring: "true"
EOF

cat << EOF| oc apply -f -
apiVersion: operators.coreos.com/v1
kind: OperatorGroup
metadata:
  name: metallb-operator
  namespace: metallb-system
EOF

cat << EOF| oc apply -f -
apiVersion: operators.coreos.com/v1alpha1
kind: Subscription
metadata:
  name: metallb-operator-sub
  namespace: metallb-system
spec:
  channel: stable
  name: metallb-operator
  source: redhat-operators
  sourceNamespace: openshift-marketplace
EOF

# Wait for the operator to be ready
until [ "$(kubectl get csv -n metallb-system | grep metallb-operator > /dev/null; echo $?)" == 0 ];
  do echo "Waiting for MetalLB operator"
  sleep 5
done
kubectl wait --for jsonpath='{.status.phase}'=Succeeded --timeout=10m -n metallb-system "$(kubectl get csv -n metallb-system -oname)"
sleep 60

cat << EOF | oc apply -f -
apiVersion: metallb.io/v1beta1
kind: MetalLB
metadata:
  name: metallb
  namespace: metallb-system
EOF

if [ ${BAREMETAL} == "true" ]; then
  # kill the ssh tunnel so the job completes
  pkill ssh
fi
