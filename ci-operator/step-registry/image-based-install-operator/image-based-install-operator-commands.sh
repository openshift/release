#!/bin/bash

set -o nounset
set -o errexit
set -o pipefail

echo "************ image based install operator command ************"

source "${SHARED_DIR}/packet-conf.sh"

echo "export BMH_EXTERNALLY_PROVISIONED=${BMH_EXTERNALLY_PROVISIONED}" | ssh "${SSHOPTS[@]}" "root@${IP}" "cat >> /root/env.sh"

ssh "${SSHOPTS[@]}" "root@${IP}" bash - << "EOF"

# prepending each printed line with a timestamp
exec > >(awk '{ print strftime("[%Y-%m-%d %H:%M:%S]"), $0 }') 2>&1

set -xeo pipefail

source /root/env.sh

cd /root/dev-scripts
source common.sh
source utils.sh
source network.sh

echo "### Download latest version of yq"
export YQ_PATH=$(which yq)
if [ -z "${YQ_PATH}" ];
then
  export YQ_PATH=/usr/local/bin/yq
else
  rm -f ${YQ_PATH}
fi
wget https://github.com/mikefarah/yq/releases/latest/download/yq_linux_amd64 -O ${YQ_PATH}
chmod +x ${YQ_PATH}

yq -i 'select(.kind == "BareMetalHost").spec.automatedCleaningMode = "disabled"' ocp/ostest/extra_host_manifests.yaml
yq -i 'select(.kind == "BareMetalHost").spec.externallyProvisioned = env(BMH_EXTERNALLY_PROVISIONED)' ocp/ostest/extra_host_manifests.yaml
oc create -f ocp/ostest/extra_host_manifests.yaml
oc create namespace ibi-cluster
oc create secret generic pull-secret -n ibi-cluster --type=kubernetes.io/dockerconfigjson --from-file=.dockerconfigjson=${PULL_SECRET_FILE}

export SEED_VERSION=$(cat /home/ib-orchestrate-vm/seed-version)

echo "### Configuring dns for ibi cluster on the host"
export IBI_VM_IP=$(cat /home/ib-orchestrate-vm/ibi-vm-ip)
echo "address=/api.ibi-cluster.mydomain.com/${IBI_VM_IP}" | sudo tee -a /etc/NetworkManager/dnsmasq.d/openshift-ibi-cluster.conf
echo "address=/.apps.ibi-cluster.mydomain.com/${IBI_VM_IP}" | sudo tee -a /etc/NetworkManager/dnsmasq.d/openshift-ibi-cluster.conf
systemctl reload NetworkManager

nslookup api.ibi-cluster.mydomain.com
nslookup a.apps.ibi-cluster.mydomain.com

echo "Configured dns successfully"

export SSH_PUB_KEY=$(cat /home/ib-orchestrate-vm/bip-orchestrate-vm/ssh-key/key.pub)

tee <<EOCR | oc create -f -
apiVersion: hive.openshift.io/v1
kind: ClusterImageSet
metadata:
  name: ibi-cluster-image-set
spec:
  releaseImage: quay.io/openshift-release-dev/ocp-release:${SEED_VERSION}-x86_64
---
apiVersion: extensions.hive.openshift.io/v1alpha1
kind: ImageClusterInstall
metadata:
  name: ibi-cluster
  namespace: ibi-cluster
spec:
  bareMetalHostRef:
    name: ostest-extraworker-0 
    namespace: openshift-machine-api
  clusterDeploymentRef:
    name: ibi-cluster
  hostname: ostest-extraworker-0 
  imageSetRef:
    name: ibi-cluster-image-set
  machineNetwork: ${EXTERNAL_SUBNET_V4}
  sshKey: ${SSH_PUB_KEY}
---
apiVersion: hive.openshift.io/v1
kind: ClusterDeployment
metadata:
  name: ibi-cluster
  namespace: ibi-cluster
spec:
  baseDomain: mydomain.com
  clusterInstallRef:
    group: extensions.hive.openshift.io
    kind: ImageClusterInstall
    name: ibi-cluster
    version: v1alpha1
  clusterName: ibi-cluster
  controlPlaneConfig:
    servingCertificates: {}
  platform:
    none: {}
  pullSecretRef:
    name: pull-secret
EOCR

echo "### Waiting for ibi cluster to finish the installation"
sleep 60
oc wait -n ibi-cluster --for=jsonpath='{.status.conditions[?(@.type=="Completed")].reason}'=ClusterInstallationSucceeded imageclusterinstalls.extensions.hive.openshift.io/ibi-cluster --timeout=60m

echo "### Check connectivity to ibi cluster"
mkdir /root/ibi-cluster
oc extract secret/ibi-cluster-admin-kubeconfig -n ibi-cluster --to /root/ibi-cluster/
oc --kubeconfig /root/ibi-cluster/kubeconfig get clusterversion,clusteroperators

EOF
