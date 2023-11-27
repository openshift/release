#!/bin/bash
set -o nounset
set -o errexit
set -o pipefail

trap 'CHILDREN=$(jobs -p); if test -n "${CHILDREN}"; then kill ${CHILDREN} && wait; fi' TERM

export KUBECONFIG=${SHARED_DIR}/kubeconfig

function echo_date() {
  echo "$(date -u --rfc-3339=seconds) - $*"
}

function update_image_registry() {
  echo_date "update_image_registry()"
  while true; do
    sleep 30;
    oc get configs.imageregistry.operator.openshift.io/cluster > /dev/null && break
  done
  oc patch configs.imageregistry.operator.openshift.io cluster --type merge --patch '{"spec":{"managementState":"Managed","storage":{"emptyDir":{}}}}'
  echo_date "update_image_registry() done"
}

function wait_for_masters() {
  echo_date "wait_for_masters()"
  set +e
  until oc wait node --selector='node-role.kubernetes.io/master' --for condition=Ready --timeout=30s; do
    echo_date "Checking masters..."
    oc get nodes -l node-role.kubernetes.io/master
    if [[ "$(oc get nodes --selector='node-role.kubernetes.io/master' --no-headers 2>/dev/null | wc -l)" -eq 3 ]] ; then
      echo_date "Found 3 masters nodes, existing..."
      break
    fi
    sleep 30
  done
  echo_date "wait_for_masters() done"
  oc get nodes -l node-role.kubernetes.io/master=''
}

function wait_for_workers() {
  # TODO improve this check
  all_approved_offset=0
  all_approved_limit=10
  all_approved_check_delay=10
  echo_date "wait_for_workers()"
  while true; do
    test $all_approved_offset -ge $all_approved_limit && break
    echo_date "Checking workers..."
    echo_date "Waiting for workers approved..."
    oc get nodes -l node-role.kubernetes.io/worker
    if [[ "$(oc get csr -ojson | jq -r '.items[] | select(.status == {} ) | .metadata.name' | wc -l)" -ge 1 ]]; then
      echo_date "Detected pending certificates, approving..."
      oc get csr -ojson | jq -r '.items[] | select(.status == {} ) | .metadata.name' | xargs --no-run-if-empty oc adm certificate approve || true
      all_approved_offset=$(( all_approved_offset + 1 ))
      sleep $all_approved_check_delay
      continue
    fi
    if [[ "$(oc get nodes --selector='node-role.kubernetes.io/worker' --no-headers 2>/dev/null | wc -l)" -eq 3 ]] ; then
      echo_date "Found 3 worker nodes, existing..."
      break
    fi
    echo_date "Waiting for certificates..."
    sleep 15
  done
  echo_date "Starting workers ready waiter..."
  until oc wait node --selector='node-role.kubernetes.io/worker' --for condition=Ready --timeout=30s; do
    oc get csr -ojson | jq -r '.items[] | select(.status == {} ) | .metadata.name' | xargs --no-run-if-empty oc adm certificate approve || true
    echo_date "Waiting for workers join..."
    sleep 10
  done
  echo_date "wait_for_workers() done"
  oc get nodes -l node-role.kubernetes.io/master=''
}

echo_date "=> Waiting for Control Plane nodes"

wait_for_masters

update_image_registry

wait_for_workers &
wait "$!"

INSTALL_DIR=/tmp
mkdir -p ${INSTALL_DIR}/auth || true
cp -vf $SHARED_DIR/kubeconfig ${INSTALL_DIR}/auth/

set +x
echo_date "Waiting for install complete..."
openshift-install --dir=${INSTALL_DIR} wait-for install-complete 2>&1 | grep --line-buffered -v password &
wait "$!"

echo_date "Install Completed!"

date "+%F %X" > "${SHARED_DIR}/CLUSTER_INSTALL_END_TIME"

# touch ${ARTIFACT_DIR}/install-complete

oc get pods -A | tee ${ARTIFACT_DIR}/oc-pods-all.yaml

oc get nodes | tee ${ARTIFACT_DIR}/oc-nodes.yaml

oc get co | tee ${ARTIFACT_DIR}/oc-clusteroperators.yaml