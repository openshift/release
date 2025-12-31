#!/bin/bash

set -o nounset
set -o errexit
set -o pipefail

# copy cluster info to SHARED_DIR
cluster_info_dir="/var/run/vault/cluster-info"

if [[ -f "${cluster_info_dir}/kubeconfig" ]]; then
    echo "INFO: find kubeconfig file, copy it to SHARED_DIR..."
    cp ${cluster_info_dir}/kubeconfig "${SHARED_DIR}"
else
    echo "ERROR: could not find kubeconfig file, exit..."
    exit 1
fi

if [[ -f "${cluster_info_dir}/kubeadmin-password" ]]; then
    echo "INFO: find kubeadmin-password file, copy it to SHARED_DIR..."
    cp ${cluster_info_dir}/kubeadmin-password "${SHARED_DIR}"
else
    echo "ERROR: could not find kubeadmin-password file, exit..."
    exit 1
fi
