#!/bin/bash

set -o nounset
set -o errexit
set -o pipefail

set -x

source "${SHARED_DIR}"/env
source "${SHARED_DIR}"/functions

opct_upi_conf_provider || true
okd_installer_setup_ocp_clients

#
# Installing
#
function create_all() {
  ansible-playbook mtulio.okd_installer.create_all \
    -e cert_max_retries=60 \
    -e cert_wait_interval_sec=45 \
    -e @"$VARS_FILE"
}

# run create with retry (idempotency will not duplicate resources)
create_all || create_all

# temp
function debug_post_create() {
    export KUBECONFIG=$OKD_INSTALLER_WORKDIR/clusters/${CLUSTER_NAME}/auth/kubeconfig
    echo "Checking and approving certificates [1/3]"
    oc get csr || true
    oc get csr -o go-template='{{range .items}}{{if not .status}}{{.metadata.name}}{{"\n"}}{{end}}{{end}}' | xargs oc adm certificate approve || true
    oc get nodes || true

    echo "Sleeping 120s to check/approve certificates [2/3]"
    sleep 120
    oc get csr || true
    oc get csr -o go-template='{{range .items}}{{if not .status}}{{.metadata.name}}{{"\n"}}{{end}}{{end}}' | xargs oc adm certificate approve || true
    oc get nodes || true

    echo "Sleeping 30s to check/approve certificates [3/3]"
    sleep 30
    oc get csr || true
    oc get csr -o go-template='{{range .items}}{{if not .status}}{{.metadata.name}}{{"\n"}}{{end}}{{end}}' | xargs oc adm certificate approve || true
    oc get nodes || true
}
debug_post_create || true

cp -vf $OKD_INSTALLER_WORKDIR/clusters/${CLUSTER_NAME}/auth/kubeconfig ${SHARED_DIR}/kubeconfig
cp -vf $OKD_INSTALLER_WORKDIR/clusters/${CLUSTER_NAME}/cluster_state.json ${SHARED_DIR}/

cp -vf ${SHARED_DIR}/env ${ARTIFACT_DIR}/env
cp -vf ${ANSIBLE_CONFIG} ${ARTIFACT_DIR}/ansible.cfg
cp -vf ${VARS_FILE} ${ARTIFACT_DIR}/cluster-vars-file.yaml

cp -vf $OKD_INSTALLER_WORKDIR/clusters/${CLUSTER_NAME}/cluster_state.json ${SHARED_DIR}/
cp -vf $OKD_INSTALLER_WORKDIR/clusters/${CLUSTER_NAME}/cluster_state.json ${ARTIFACT_DIR}/