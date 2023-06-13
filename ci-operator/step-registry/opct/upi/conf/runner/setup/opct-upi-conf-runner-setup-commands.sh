#!/bin/bash

set -o nounset
set -o errexit
set -o pipefail

set -x

export OC_BIN="/usr/bin/oc"
export INSTALLER_BIN="/usr/bin/openshift-install"

# discover cluster version based in installer binary
current_release=$($INSTALLER_BIN version | head -n 1 | awk '{print$2}')

if [[ "$current_release" == "null" ]]; then export current_release="4.14.0-ec.3" ; fi

#
# Setting up Ansible Project and okd-installer Colellection
#

# Shared env var
cat >> "${SHARED_DIR}"/env << EOF
export ANSIBLE_CONFIG=${SHARED_DIR}/ansible.cfg
export ANSIBLE_REMOTE_TMP="/tmp/ansible-tmp-remote"
export ANSIBLE_LOG_PATH=/tmp/okd-installer/opct-runner.log
export OKD_INSTALLER_WORKDIR=/tmp/okd-installer
export VARS_FILE="${SHARED_DIR}/okd_installer-vars.yaml"
export SSH_KEY_PATH=/var/run/vault/opct-splat/ssh-key
export CLUSTER_VERSION=${current_release}
EOF

source "${SHARED_DIR}"/env

# Ansible Config
cat >> ${ANSIBLE_CONFIG} << EOF
[defaults]
local_tmp=${OKD_INSTALLER_WORKDIR}/tmp-local
callbacks_enabled=ansible.posix.profile_roles
hash_behavior=merge

[inventory]
enable_plugins = yaml, ini
EOF

cat >> "${SHARED_DIR}"/functions << EOF

function okd_installer_setup_ocp_clients() {
    mkdir -p ${OKD_INSTALLER_WORKDIR}/bin
    if [[ -f "$OC_BIN" ]]; then
        ln -svf "$OC_BIN" ${OKD_INSTALLER_WORKDIR}/bin/oc-linux-$CLUSTER_VERSION
        ln -svf "$OC_BIN" ${OKD_INSTALLER_WORKDIR}/bin/kubectl-linux-$CLUSTER_VERSION
    else
        echo "Failed to find openshift client";
        # exit 1
    fi

    if [[ -f "$INSTALLER_BIN" ]]; then
        ln -svf "$INSTALLER_BIN" ${OKD_INSTALLER_WORKDIR}/bin/openshift-install-linux-$CLUSTER_VERSION
    else
        echo "Failed to find openshift installer binary";
        # exit 1
    fi
}
EOF

mkdir -p $OKD_INSTALLER_WORKDIR
ansible-galaxy collection list

cp -v "${ANSIBLE_CONFIG}" "${ARTIFACT_DIR}"/
cp -v "${SHARED_DIR}"/env "${ARTIFACT_DIR}"/env
cp -v "${SHARED_DIR}"/functions "${ARTIFACT_DIR}"/functions