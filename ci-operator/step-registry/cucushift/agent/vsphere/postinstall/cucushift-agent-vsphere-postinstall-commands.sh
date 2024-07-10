#!/bin/bash

set -o nounset
set -o errexit
set -o pipefail

echo "************ vsphere agent post-install ************"

# Debug
export KUBECONFIG=${SHARED_DIR}/kubeconfig
version=$(oc get clusterversion -o jsonpath={..desired.version} | cut -d '.' -f 1,2)
# Skip post installation if the version is 4.15 or more
if [[ $(echo -e "4.15\n$version" | sort -V | tail -n 1) == "$version" ]]; then
  echo "$(date -u --rfc-3339=seconds) - credentials have been added to the cluster, there's no need to execute post-installation."
  exit 0
fi
# Check for SNO cluster
if [ "${MASTERS}" -eq 1 ]; then
  echo "$(date -u --rfc-3339=seconds) - no need to add vsphere credentials as the cluster is SNO"
  exit 0
fi
source "${SHARED_DIR}"/platform-conf.sh

oc get nodes

# Backup
echo "Getting vsphere-creds and cloud-provider-config"
oc get secret vsphere-creds -o yaml -n kube-system >"${SHARED_DIR}"/vsphere-creds.yaml
oc get cm cloud-provider-config -o yaml -n openshift-config >"${SHARED_DIR}"/cloud-provider-config.yaml

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

echo "Applying changes on cloud-provider-config"
oc get cm cloud-provider-config -o yaml -n openshift-config >"${SHARED_DIR}"/cloud-provider-config.yaml
sed -i -e "s/vcenterplaceholder/${VSPHERE_VCENTER}/g" \
  -e "s/datacenterplaceholder/${VSPHERE_DATACENTER}/g" \
  -e "s/clusterplaceholder\/\/Resources/${VSPHERE_CLUSTER}\/Resources\/ipi-ci-clusters/g" \
  -e "s/clusterplaceholder/${VSPHERE_CLUSTER}/g" \
  -e "s/defaultdatastoreplaceholder/${VSPHERE_DATASTORE}/g" \
  -e "s/networkplaceholder/${VSPHERE_NETWORK}/g" \
  -e "s/folderplaceholder/${VSPHERE_FOLDER}/g" "${SHARED_DIR}"/cloud-provider-config.yaml

oc apply -f "${SHARED_DIR}"/cloud-provider-config.yaml

# Do the following if OCP version is >=4.13
if [[ $(echo -e "4.13\n$version" | sort -V | tail -n 1) == "$version" ]]; then
  echo "Found OCP version $version"
  # Taint the nodes with the uninitialized taint
  nodes=$(oc get nodes -o wide | awk '{print $1}' | tail -n +2)
  for NODE in $nodes; do
    oc adm taint node "$NODE" node.cloudprovider.kubernetes.io/uninitialized=true:NoSchedule || true
  done
      oc get infrastructures.config.openshift.io -o yaml >"${SHARED_DIR}"/infrastructures.config.openshift.io.yaml
      sed -i -e "s/vcenterplaceholder/${VSPHERE_VCENTER}/g" \
        -e "s/datacenterplaceholder/${VSPHERE_DATACENTER}/g" \
        -e "s/clusterplaceholder\/\/Resources/${VSPHERE_CLUSTER}\/Resources\/ipi-ci-clusters/g" \
        -e "s/clusterplaceholder/${VSPHERE_CLUSTER}/g" \
        -e "s/defaultdatastoreplaceholder/${VSPHERE_DATASTORE}/g" \
        -e "s/networkplaceholder/${VSPHERE_NETWORK}/g" \
        -e "s/folderplaceholder/${VSPHERE_FOLDER}/g" "${SHARED_DIR}"/infrastructures.config.openshift.io.yaml
      oc apply -f "${SHARED_DIR}"/infrastructures.config.openshift.io.yaml --overwrite=true
fi

oc patch kubecontrollermanager cluster -p='{"spec": {"forceRedeploymentReason": "recovery-'"$(date --rfc-3339=ns)"'"}}' --type=merge

oc patch clusterversion version --type json -p '[{"op": "remove", "path": "/spec/channel"}]}]'

oc adm wait-for-stable-cluster --minimum-stable-period=5m --timeout=60m

oc get co
