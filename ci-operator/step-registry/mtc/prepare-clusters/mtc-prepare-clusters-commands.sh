#!/bin/bash
set -o nounset
set -o errexit
set -o pipefail

echo "Extracting cluster data."
tar -xzvf "${SHARED_DIR}/clusters_data.tar.gz" --one-top-leve=/tmp/clusters-data

# Install the Operator on both clusters
echo "Installing the MTC operator on the source cluster."
ansible-playbook /mtc-interop/install-mtc.yml \
    -e version=${MTC_VERSION} \
    -e isController=true \
    -e kubeconfig_path=/tmp/clusters-data/aws/mtc-aws-ipi-source/auth/kubeconfig

echo "Installing the MTC operator on the target cluster."
ansible-playbook /mtc-interop/install-mtc.yml \
    -e version=${MTC_VERSION} \
    -e kubeconfig_path=/tmp/clusters-data/aws/mtc-aws-ipi-target/auth/kubeconfig


# Configure the clusters prior to executing tests
echo "Configuring the source and target clusters."
ansible-playbook /mtc-interop/config_mtc.yml \
    -e controller_kubeconfig=/tmp/clusters-data/aws/mtc-aws-ipi-source/auth/kubeconfig \
    -e cluster_kubeconfig=/tmp/clusters-data/aws/mtc-aws-ipi-target/auth/kubeconfig
