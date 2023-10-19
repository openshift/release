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
    -e kubeconfig_path=/tmp/clusters-data/aws/mtc-aws-ipi-target/auth/kubeconfig

echo "Installing the MTC operator on the target cluster."
ansible-playbook /mtc-interop/install-mtc.yml \
    -e version=${MTC_VERSION} \
    -e kubeconfig_path=/tmp/clusters-data/aws/mtc-aws-ipi-source/auth/kubeconfig

cp /mtc-interop/usr/bin/oc/oc /usr/bin/oc
SOURCE_KUBEADMIN_PASSWORD_FILE="/tmp/clusters-data/aws/mtc-aws-ipi-target/auth/kubeadmin-password"
SOURCE_KUBECONFIG="/tmp/clusters-data/aws/mtc-aws-ipi-target/auth/kubeconfig"
SOURCE_KUBEADMIN_PASSWORD=$(cat $SOURCE_KUBEADMIN_PASSWORD_FILE)
export KUBECONFIG=$SOURCE_KUBECONFIG
oc login -u kubeadmin -p $SOURCE_KUBEADMIN_PASSWORD

oc patch configs.imageregistry.operator.openshift.io/cluster --patch '{"spec":{"defaultRoute":true}}' --type=merge && sleep 10
export EXPOSED_REGISTRY_PATH=$(oc get route default-route  -n openshift-image-registry -o jsonpath='{.spec.host}')

sleep 2500

# Configure the clusters prior to executing tests
echo "Configuring the source and target clusters."
ansible-playbook /mtc-interop/config_mtc.yml \
    -e controller_kubeconfig=/tmp/clusters-data/aws/mtc-aws-ipi-target/auth/kubeconfig \
    -e cluster_kubeconfig=/tmp/clusters-data/aws/mtc-aws-ipi-source/auth/kubeconfig \
    -e exposed_registry_path=${EXPOSED_REGISTRY_PATH}

