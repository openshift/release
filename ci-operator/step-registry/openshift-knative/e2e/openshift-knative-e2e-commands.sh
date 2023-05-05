#!/bin/bash
set -o errexit
set -o nounset
set -o pipefail
set -x

echo "This is the start SHARED_DIR: ${SHARED_DIR}"
echo "password is: $SHARED_DIR/kubeadmin-password"
echo "$(cat $SHARED_DIR/kubeadmin-password)"

echo "$(ls -all $SHARED_DIR)"
export KUBECONFIG="$SHARED_DIR/.kube/config"
echo "KUBECONFIG: ${KUBECONFIG}"

CONSOLE_URL=$(cat $SHARED_DIR/console.url)
API_URL="https://api.${CONSOLE_URL#"https://console-openshift-console.apps."}:6443"

echo "Login as Kubeadmin to the test cluster at ${API_URL}..."
mkdir -p $SHARED_DIR/.kube
touch $SHARED_DIR/.kube/config
oc login -u kubeadmin -p "$(cat $SHARED_DIR/kubeadmin-password)" "${API_URL}" --insecure-skip-tls-verify=true
oc whoami --show-console

echo "Login in my openstack cluster:"
oc login https://api.liswang-test.osp.interop.ccitredhat.com:6443 --insecure-skip-tls-verify=true -u kubeadmin -p ywCdP-vQcho-xctBj-kmxoX
oc whoami --show-console

oc get nodes -o wide

echo "get running worker count:"
oc -n openshift-machine-api get machines -l "machine.openshift.io/cluster-api-machine-role=worker" -o json

echo "get worker machine set:"
oc -n openshift-machine-api get machineset -o json

echo "get machine:"
oc  -n openshift-machine-api get machines

echo "scale cluster:"
first_worker_machine_set=3
new_machineset_count=4
oc -n openshift-machine-api scale machineset "$first_worker_machine_set" --replicas="$new_machineset_count"
sleep 80000
make test-e2e-with-kafka