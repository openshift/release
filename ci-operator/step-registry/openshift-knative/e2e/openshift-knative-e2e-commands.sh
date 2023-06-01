#!/bin/bash
set -o errexit
set -o nounset
set -o pipefail
set -x

echo "This is the start SHARED_DIR: ${SHARED_DIR}"
echo "ARTIFACT_DIR: ${ARTIFACT_DIR}"
SECRETS_DIR="/tmp/secrets/ci"
#echo "password is: $SHARED_DIR/kubeadmin-password"
#echo "$(cat $SHARED_DIR/kubeadmin-password)"

#export KUBECONFIG="$SHARED_DIR/.kube/config"

#mkdir -p $SHARED_DIR/.kube
#touch $SHARED_DIR/.kube/config
#cp ${SECRETS_DIR}/ci/kubeconfig $SHARED_DIR/.kube/config
#cp ${SECRETS_DIR}/ci/kubeadmin-password $SHARED_DIR/kubeadmin-password
#echo "password: $(cat $SECRETS_DIR/ci/kubeadmin-password)"
#echo "kubeconfig: $(cat $SECRETS_DIR/ci/kubeconfig)"

#echo "password: $(cat $SECRETS_DIR/ci/password)"
#echo "username: $(cat $SECRETS_DIR/ci/username)"

echo "$(ls -all ${SECRETS_DIR})"

unset KUBECONFIG
oc login https://api.fipstest.sivw.p1.openshiftapps.com:6443 --username cluster-admin --password "$(cat $SECRETS_DIR/kubeadmin-password)" || true

docker login -u="$(cat $SECRETS_DIR/username)" -p="$(cat $SECRETS_DIR/password)" quay.io || true

docker pull quay.io/cspi-qe-images/opp:test || true

docker pull quay.io/cloudservices/iqe-tests:latest || true

iqe tests plugin cost_management -m cost_interop -vv --junitxml="test_run.xml" || true

#export KUBECONFIG="${SECRETS_DIR}/kubeconfig"

#oc login https://api.ci-ln-bz6wd82-76ef8.aws-2.ci.openshift.org:6443 --insecure-skip-tls-verify=true -u kubeadmin -p 2RddM-mufnh-PMEhh-YBYe4

#oc whoami
#oc whoami --show-server
#API_URL=$(oc whoami --show-server)
#echo "API_URL: ${API_URL}"
#cluster_name=${NAMESPACE}-${JOB_NAME_HASH}

#CONSOLE_URL=$(cat $SHARED_DIR/console.url)
#API_URL="https://api.${CONSOLE_URL#"https://console-openshift-console.apps."}:6443"
#API_URL="https://api.liswang-test.osp.interop.ccitredhat.com:6443"
#echo "Login as Kubeadmin to the test cluster at ${API_URL}..."

#oc login -u kubeadmin -p "$(cat $SECRETS_DIR/ci/kubeadmin-password)" "${API_URL}" --insecure-skip-tls-verify=true
#oc login -u kubeadmin -p ywCdP-vQcho-xctBj-kmxoX "${API_URL}" --insecure-skip-tls-verify=true
#oc login https://api.liswang-test.osp.interop.ccitredhat.com:6443 --insecure-skip-tls-verify=true -u kubeadmin -p ywCdP-vQcho-xctBj-kmxoX

info "Current node/machine state:"

#if [[ -n "${ARTIFACT_DIR:-}" ]]; then
#    scale_debug_dir="${ARTIFACT_DIR}/openshift/scaling-debug"
#    mkdir -p "${scale_debug_dir}"
#    oc -n openshift-machine-api get machineset -o json > "${scale_debug_dir}/machineset.json"
#    oc -n openshift-machine-api get machines -o json > "${scale_debug_dir}/machines.json"
#fi
#original_count="$(get_running_worker_count)"
#first_worker_machine_set="$(get_first_worker_machine_set)"
#current_replicas="$(oc -n openshift-machine-api get machineset "$first_worker_machine_set" -o json | jq -r '.spec.replicas')"
#new_machineset_count=$((current_replicas + 1))
#first_worker_machine_set="$(oc -n openshift-machine-api get machineset -o json | jq -r '[.items[] |select(.spec.template.metadata.labels["machine.openshift.io/cluster-api-machine-role"]=="worker")][0] | .metadata.name'
#)"
#original_count="$(oc -n openshift-machine-api get machines -l "machine.openshift.io/cluster-api-machine-role=worker" -o json |     jq -r '.items | length')"
#echo "original_count: $original_count"
#current_replicas="$(oc -n openshift-machine-api get machineset "$first_worker_machine_set" -o json | jq -r '.spec.replicas')"
#new_machineset_count=$((current_replicas + 1))
#oc -n openshift-machine-api scale machineset "$first_worker_machine_set" --replicas="$new_machineset_count"

#expected_count=$((original_count + 1))
# note: timeout of this loop is handled by the calling context
#while [[ "$(get_running_worker_count)" != "$expected_count" ]]; do
#    info "Current machine state does not have the running count we desire ($expected_count)"
#    oc  -n openshift-machine-api get machines
#    sleep 20
#done

#make test-e2e-with-kafka
#make teardown

sleep 10