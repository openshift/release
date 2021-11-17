#!/usr/bin/env bash

set -o nounset
set -o errexit
set -o pipefail
if "$VFIO_NETWORK_ID" == "" ; then
  VFIO_NETWORK_ID=$(<"${SHARED_DIR}"/VFIO_NETWORK_ID)
fi
## Enabling VFIO noiommu
## https://docs.openshift.com/container-platform/4.9/installing/installing_openstack/installing-openstack-user-sr-iov.html#networking-osp-enabling-vfio-noiommu_installing-openstack-user-sr-iov
# Machine config to add  "enable_unsafe_noiommu_mode=1" option to vfio kernel module.
cat > 05-vfio-noiommu.yaml <<EOF
kind: MachineConfig
apiVersion: machineconfiguration.openshift.io/v1
metadata:
  name: 99-vfio-noiommu 
  labels:
    machineconfiguration.openshift.io/role: worker
spec:
  config:
    ignition:
      version: 3.2.0
    storage:
      files:
      - path: /etc/modprobe.d/vfio-noiommu.conf
        mode: 0644
        contents:
          source: data:;base64,b3B0aW9ucyB2ZmlvIGVuYWJsZV91bnNhZmVfbm9pb21tdV9tb2RlPTEK
EOF
echo "Creating VFIO NoIOMMU MachineConfig"
oc create -f 05-vfio-noiommu.yaml

# Machine config to create systemd unit that binds vfio-pci kernel driver to the ports attached to
# network specified by VFIO_NETWORK_ID
git clone https://github.com/rh-nfv-int/shift-on-stack-vhostuser/
cd shift-on-stack-vhostuser
#we have to set path to kubeconfig before executing playbook.
#playbooks will use K8S_AUTH_KUBECONFIG enviroment. see https://docs.ansible.com/ansible/latest/collections/community/kubernetes/k8s_module.html
export K8S_AUTH_KUBECONFIG=${KUBECONFIG}
#Following playbook creates and applies the 99-vhostuser-bind machineconfig which binds the vfio-pci kernel driver
# to the port attached to VFIO_NETWORK_ID
ansible-playbook play.yaml -e network_ids="${VFIO_NETWORK_ID}"
