#!/bin/bash
set -o errexit
set -o nounset
set -o pipefail
set -x

echo "This is the start SHARED_DIR: ${SHARED_DIR}"

#SECRETS_DIR="/tmp/secrets"
#export KUBECONFIG="{SHARED_DIR}/.kube/config"

CONSOLE_URL=$(cat $SHARED_DIR/console.url)
API_URL="https://api.${CONSOLE_URL#"https://console-openshift-console.apps."}:6443"

echo "Login as Kubeadmin to the test cluster at ${API_URL}..."
mkdir -p $SHARED_DIR/.kube
touch $SHARED_DIR/.kube/config
oc login -u kubeadmin -p "$(cat $SHARED_DIR/kubeadmin-password)" "${API_URL}" --insecure-skip-tls-verify=true
oc whoami --show-server

info "Current node/machine state:"

first_worker_machine_set="$(oc -n openshift-machine-api get machineset -o json | jq -r '[.items[] |select(.spec.template.metadata.labels["machine.openshift.io/cluster-api-machine-role"]=="worker")][0] | .metadata.name'
)"
original_count="$(oc -n openshift-machine-api get machines -l "machine.openshift.io/cluster-api-machine-role=worker" -o json |     jq -r '.items | length')"
echo "original_count: $original_count"
current_replicas="$(oc -n openshift-machine-api get machineset "$first_worker_machine_set" -o json | jq -r '.spec.replicas')"
new_machineset_count=$((current_replicas + 1))
oc -n openshift-machine-api scale machineset "$first_worker_machine_set" --replicas="$new_machineset_count"

#expected_count=$((original_count + 1))
# note: timeout of this loop is handled by the calling context
#while [[ "$(get_running_worker_count)" != "$expected_count" ]]; do
#    info "Current machine state does not have the running count we desire ($expected_count)"
#    oc  -n openshift-machine-api get machines
#    sleep 20
#done

#make test-e2e-with-kafka
#make teardown

ifconfig | grep 'inet ' | grep -v '127.0.0.1' | awk '{print $2}' || true
sleep 600