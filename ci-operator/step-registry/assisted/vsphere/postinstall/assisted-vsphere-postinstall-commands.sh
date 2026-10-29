#!/bin/bash

set -o nounset
set -o errexit
set -o pipefail

echo "************ vsphere assisted test-infra post-install ************"
source "${SHARED_DIR}"/platform-conf.sh

# Debug
export KUBECONFIG=${SHARED_DIR}/kubeconfig

/usr/local/bin/fix_uid.sh
ssh -F "${SHARED_DIR}/ssh_config" "root@ci_machine" "find \${KUBECONFIG} -type f -exec cat {} \;" > "${KUBECONFIG}"
oc get nodes

# Backup
echo "Getting vsphere-creds and cloud-provider-config"
oc get secret vsphere-creds -o yaml -n kube-system > vsphere-creds.yaml
oc get cm cloud-provider-config -o yaml -n openshift-config > cloud-provider-config.yaml


version=$(oc version | grep -oE 'Server Version: ([0-9]+\.[0-9]+)' | sed 's/Server Version: //')


cat <<EOF | oc replace -f -
apiVersion: v1
kind: Secret
metadata:
  annotations:
    cloudcredential.openshift.io/mode: passthrough
  name: vsphere-creds
  namespace: kube-system
type: Opaque
stringData:
  "${VSPHERE_VCENTER}.username": "${VSPHERE_USERNAME}"
  "${VSPHERE_VCENTER}.password": "${VSPHERE_PASSWORD}"
EOF

oc patch kubecontrollermanager cluster -p='{"spec": {"forceRedeploymentReason": "recovery-'"$( date --rfc-3339=ns )"'"}}' --type=merge

CLOUD_CONFIG="cloud-provider-config.yaml"

oc get cm cloud-provider-config -o yaml -n openshift-config > ${CLOUD_CONFIG}

cat ${CLOUD_CONFIG}

echo "${VSPHERE_VCENTER} ${VSPHERE_DATACENTER} ${VSPHERE_CLUSTER} ${VSPHERE_CLUSTER} ${VSPHERE_DATASTORE} ${VSPHERE_NETWORK} ${VSPHERE_FOLDER}"

# Since paths are being created below get the basename of each vCenter object if provided full path
bn_vsphere_datacenter=$(basename "${VSPHERE_DATACENTER}")
bn_vsphere_cluster=$(basename "${VSPHERE_CLUSTER}")
bn_vsphere_datastore=$(basename "${VSPHERE_DATASTORE}")
bn_vsphere_network=$(basename "${VSPHERE_NETWORK}")
bn_vsphere_folder=$(basename "${VSPHERE_FOLDER}")


sed -i -e "s/vcenterplaceholder/${VSPHERE_VCENTER}/g" \
       -e "s/datacenterplaceholder/${bn_vsphere_datacenter}/g" \
       -e "s/clusterplaceholder\/\/Resources/${bn_vsphere_cluster}\/Resources/g" \
       -e "s/clusterplaceholder/${bn_vsphere_cluster}/g" \
       -e "s/defaultdatastoreplaceholder/${bn_vsphere_datastore}/g" \
       -e "s/networkplaceholder/${bn_vsphere_network}/g" \
       -e "s/folderplaceholder/${bn_vsphere_folder}/g" ${CLOUD_CONFIG}

cat ${CLOUD_CONFIG}
echo "Applying changes on cloud-provider-config"
oc apply -f ${CLOUD_CONFIG}

# Do the following if OCP version is >=4.13
if [[ $(echo -e "4.13\n$version" | sort -V | tail -n 1) == "$version" ]]; then
  echo "Found OCP version $version"
    # Taint the nodes with the uninitialized taint
    nodes=$(oc get nodes -o wide | awk '{print $1}' | tail -n +2)
    for NODE in $nodes; do
      oc adm taint node "$NODE" node.cloudprovider.kubernetes.io/uninitialized=true:NoSchedule
    done
      oc get infrastructures.config.openshift.io -o yaml > infrastructures.config.openshift.io.yaml
      sed -i -e "s/vcenterplaceholder/${VSPHERE_VCENTER}/g" \
       -e "s/datacenterplaceholder/${bn_vsphere_datacenter}/g" \
       -e "s/clusterplaceholder\/\/Resources/${bn_vsphere_cluster}\/Resources/g" \
       -e "s/clusterplaceholder/${bn_vsphere_cluster}/g" \
       -e "s/defaultdatastoreplaceholder/${bn_vsphere_datastore}/g" \
       -e "s/networkplaceholder/${bn_vsphere_network}/g" \
       -e "s/folderplaceholder/${bn_vsphere_folder}/g" infrastructures.config.openshift.io.yaml
      oc apply -f infrastructures.config.openshift.io.yaml --overwrite=true
fi

oc patch clusterversion version --type json -p '[{"op": "remove", "path": "/spec/channel"}]}]'

until \
  oc wait --all=true clusteroperator --for='condition=Available=True' >/dev/null && \
  oc wait --all=true clusteroperator --for='condition=Progressing=False' >/dev/null && \
  oc wait --all=true clusteroperator --for='condition=Degraded=False' >/dev/null;  do
    echo "$(date --rfc-3339=seconds) Clusteroperators not yet ready"
    sleep 1s
done
