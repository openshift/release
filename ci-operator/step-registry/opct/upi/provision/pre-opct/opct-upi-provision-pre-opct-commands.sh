#!/bin/bash

set -o nounset
set -o errexit
set -o pipefail

set -x

#
# Setting up Ansible Project and okd-installer Colellection
#

# Setup Ansible Project

cat ${SHARED_DIR}/env

export KUBECONFIG=${SHARED_DIR}/kubeconfig
source ${SHARED_DIR}/env

mkdir -p ${OKD_INSTALLER_WORKDIR}/clusters/$CLUSTER_NAME/auth/
ln -svf ${SHARED_DIR}/kubeconfig ${OKD_INSTALLER_WORKDIR}/clusters/$CLUSTER_NAME/auth/kubeconfig

ansible-playbook /opct-runner/opct-run-tool-preflight.yaml \
    -e cluster_name=$CLUSTER_NAME \
    -e @$VARS_FILE || true