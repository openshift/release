#!/bin/bash
set -o nounset
set -o errexit
set -o pipefail

echo "Extracting cluster data"
tar -xzvf "${SHARED_DIR}/clusters_data.tar.gz" --one-top-leve=/tmp/clusters-data

SOURCE_CLUSTER_DIR=$(find tmp/clusters-data/${TEST_PLATFORM} -type d -name "${SOURCE_CLUSTER_PREFIX}*")
TARGET_CLUSTER_DIR=$(find tmp/clusters-data/${TEST_PLATFORM} -type d -name "${TARGET_CLUSTER_PREFIX}*")

SOURCE_KUBEADMIN_PASSWORD_FILE="/${SOURCE_CLUSTER_DIR}/auth/kubeadmin-password"
SOURCE_KUBECONFIG="/${SOURCE_CLUSTER_DIR}/auth/kubeconfig"
SOURCE_KUBEADMIN_PASSWORD=$(cat $SOURCE_KUBEADMIN_PASSWORD_FILE)
TARGET_KUBECONFIG="/${TARGET_CLUSTER_DIR}/auth/kubeconfig"

# Install the Operator on both clusters
echo "Installing the MTC operator on the source cluster"
ansible-playbook /mtc-interop/install-mtc.yml \
    -e version=${MTC_VERSION} \
    -e kubeconfig_path=${SOURCE_KUBECONFIG}

echo "Installing the MTC operator on the target cluster"
ansible-playbook /mtc-interop/install-mtc.yml \
    -e version=${MTC_VERSION} \
    -e isController=true \
    -e kubeconfig_path=${TARGET_KUBECONFIG}

# Log into target cluster
cp /mtc-interop/usr/bin/oc/oc /usr/bin/oc
export KUBECONFIG=$SOURCE_KUBECONFIG
oc login -u kubeadmin -p $SOURCE_KUBEADMIN_PASSWORD

echo "Retrieving source cluster exposed registry path"
oc patch configs.imageregistry.operator.openshift.io/cluster --patch '{"spec":{"defaultRoute":true}}' --type=merge && sleep 10
EXPOSED_REGISTRY_PATH=$(oc get route default-route  -n openshift-image-registry -o jsonpath='{.spec.host}')

# Configure the clusters prior to executing tests
echo "Configuring the source and target clusters"
ansible-playbook /mtc-interop/config_mtc.yml \
    -e controller_kubeconfig=${TARGET_KUBECONFIG} \
    -e cluster_kubeconfig=${SOURCE_KUBECONFIG} \
    -e exposed_registry_path=${EXPOSED_REGISTRY_PATH}

# Prepare Target cluster to match static kubeconfig path for the next step 'cucushift-installer-check-cluster-health':
cp $TARGET_KUBECONFIG ${SHARED_DIR}/kubeconfig