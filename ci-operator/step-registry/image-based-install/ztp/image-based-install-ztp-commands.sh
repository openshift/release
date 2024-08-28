#!/bin/bash

set -o nounset
set -o errexit
set -o pipefail

echo "************ image based install ztp command ************"

source "${SHARED_DIR}/packet-conf.sh"

ssh "${SSHOPTS[@]}" "root@${IP}" bash - << EOF

# prepending each printed line with a timestamp
exec > >(awk '{ print strftime("[%Y-%m-%d %H:%M:%S]"), \$0 }') 2>&1

set -xeo pipefail

cd /root/dev-scripts
source common.sh
source utils.sh
source network.sh

yq -iy 'select(.kind == "BareMetalHost").spec.automatedCleaningMode="disabled"' ocp/ostest/extra_host_manifests.yaml
oc apply -f ocp/ostest/extra_host_manifests.yaml
oc create namespace ibi-cluster
oc create secret generic pull-secret -n ibi-cluster --type=kubernetes.io/dockerconfigjson --from-file=.dockerconfigjson=\${PULL_SECRET_FILE}

export SEED_VERSION=\$(cat /home/ib-orchestrate-vm/seed-version)

echo "### Configuring dns for ibi cluster on the host"
export IBI_VM_IP=\$(cat /home/ib-orchestrate-vm/ibi-vm-ip)
echo "address=/api.ibi-cluster.mydomain.com/\${IBI_VM_IP}" | sudo tee -a /etc/NetworkManager/dnsmasq.d/openshift-ibi-cluster.conf
echo "address=/.apps.ibi-cluster.mydomain.com/\${IBI_VM_IP}" | sudo tee -a /etc/NetworkManager/dnsmasq.d/openshift-ibi-cluster.conf
sudo systemctl reload NetworkManager

nslookup api.ibi-cluster.mydomain.com
nslookup a.apps.ibi-cluster.mydomain.com

echo "Configured dns successfully"

tee <<EOCR | oc apply -f -
apiVersion: hive.openshift.io/v1
kind: ClusterImageSet
metadata:
  name: ibi-cluster-image-set
spec:
  releaseImage: quay.io/openshift-release-dev/ocp-release:\${SEED_VERSION}-x86_64
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
  machineNetwork: \${EXTERNAL_SUBNET_V4}
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
oc wait -n ibi-cluster --for=jsonpath='{.status.conditions[?(@.type=="Completed")].reason}'=ClusterInstallationSucceeded imageclusterinstalls.extensions.hive.openshift.io/ibi-cluster --timeout=60m || echo "### Failed"

oc get imageclusterinstall ibi-cluster -n ibi-cluster -o yaml
oc get clusterdeployment ibi-cluster -n ibi-cluster -o yaml

sleep 3600

EOF
