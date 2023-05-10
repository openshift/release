#!/bin/bash

set -o nounset
set -o errexit
set -o pipefail

echo "************ vsphere assisted test-infra post-install ************"
source ${SHARED_DIR}/platform-conf.sh

# Debug
export KUBECONFIG=${SHARED_DIR}/kubeconfig

/usr/local/bin/fix_uid.sh
ssh -F ${SHARED_DIR}/ssh_config "root@ci_machine" "find \${KUBECONFIG} -type f -exec cat {} \;" > ${KUBECONFIG}
oc get nodes

# Backup
echo "Getting vsphere-creds and cloud-provider-config"
oc get secret vsphere-creds -o yaml -n kube-system > vsphere-creds.yaml
oc get cm cloud-provider-config -o yaml -n openshift-config > cloud-provider-config.yaml

function compare_versions {
    local ver1=$1
    local ver2=$2
    local ver1_major
    local ver1_minor
    local ver2_major
    local ver2_minor

    if [[ $ver1 == "$ver2" ]]; then
        return 1  # Versions are equal or smaller
    fi
    ver1_major=$(echo "$ver1" | cut -d"." -f1)
    ver1_minor=$(echo "$ver1" | cut -d"." -f2)
    ver2_major=$(echo "$ver2" | cut -d"." -f1)
    ver2_minor=$(echo "$ver2" | cut -d"." -f2)
    if [[ ver1_major -gt $ver2_major || (ver1_major -eq $ver2_major && $ver1_minor -gt $ver2_minor) ]]; then
        return 0  # Version 1 is greater
    else
        return 1  # Version 2 is greater
    fi
}

cat <<EOF > replace_script.py
import os
import sys

file = sys.argv[1]

with open(file) as f:
    data = f.read()

server = os.environ.get("VSPHERE_VCENTER")
cluster = os.environ.get("VSPHERE_CLUSTER")
datacenter = os.environ.get("VSPHERE_DATACENTER")
datastore = os.environ.get("VSPHERE_DATASTORE")
network = os.environ.get("VSPHERE_NETWORK")
folder = os.environ.get("VSPHERE_FOLDER")
username = os.environ.get("VSPHERE_USERNAME")
password = os.environ.get("VSPHERE_PASSWORD")

data = data.replace("vcenterplaceholder", server)
data = data.replace("datacenterplaceholder", datacenter)
data = data.replace("clusterplaceholder//Resources", cluster + "/Resources")
data = data.replace("clusterplaceholder", cluster)
data = data.replace("defaultdatastoreplaceholder", datastore)
data = data.replace("networkplaceholder", network)
data = data.replace("folderplaceholder", folder)
data = data.replace("usernameplaceholder", username)
data = data.replace("passwordplaceholder", password)

with open(file, "w") as f:
    f.write(data)
EOF


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

# Do the following if OCP version is >=4.13
compare_versions "$version" "4.12"
if [[ $? -eq 0 ]]; then
    # Taint the nodes with the uninitialized taint
    nodes=$(oc get nodes -o wide | awk '{print $1}' | tail -n +2)
    for NODE in $nodes; do
      oc adm taint node "$NODE" node.cloudprovider.kubernetes.io/uninitialized=true:NoSchedule

      oc get infrastructures.config.openshift.io -o yaml > infrastructures.config.openshift.io.yaml
      python replace_script.py infrastructures.config.openshift.io.yaml
      oc apply -f infrastructures.config.openshift.io.yaml --overwrite=true
done
fi

echo "Applying changes on cloud-provider-config"
oc get cm cloud-provider-config -o yaml -n openshift-config > cloud-provider-config.yaml
python replace_script.py cloud-provider-config.yaml
cat cloud-provider-config.yaml
oc apply -f cloud-provider-config.yaml

oc patch clusterversion version --type json -p '[{"op": "remove", "path": "/spec/channel"}]}]'

until \
  oc wait --all=true clusteroperator --for='condition=Available=True' >/dev/null && \
  oc wait --all=true clusteroperator --for='condition=Progressing=False' >/dev/null && \
  oc wait --all=true clusteroperator --for='condition=Degraded=False' >/dev/null;  do
    echo "$(date --rfc-3339=seconds) Clusteroperators not yet ready"
    sleep 1s
done
