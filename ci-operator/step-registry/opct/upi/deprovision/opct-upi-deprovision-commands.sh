#!/bin/bash

set -o nounset
set -o errexit
set -o pipefail

set -x

source ${SHARED_DIR}/env

#
# Deprovisioning command
#
mkdir $HOME/.oci
ln -svf $OCI_CLI_CONFIG_FILE $HOME/.oci/config

mkdir -p ${OKD_INSTALLER_WORKDIR}/clusters/$CLUSTER_NAME/auth/
ln -svf ${SHARED_DIR}/cluster_state.json ${OKD_INSTALLER_WORKDIR}/clusters/$CLUSTER_NAME/cluster_state.json

ansible-playbook mtulio.okd_installer.destroy_cluster -e @$VARS_FILE