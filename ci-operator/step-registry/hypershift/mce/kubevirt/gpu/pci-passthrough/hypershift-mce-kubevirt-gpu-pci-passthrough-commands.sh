#!/bin/bash

set -o nounset
set -o errexit
set -o pipefail
set -x

curl -sSL "https://mirror2.openshift.com/pub/openshift-v4/clients/butane/latest/butane" --output /tmp/butane && chmod +x /tmp/butane

# generate array with current version + previous one, this is needed for non-GA releases where Butane doesn't support yet the latest version
VERSION=$(oc get clusterversion version -o jsonpath='{.status.desired.version}' | awk -F. -v OFS=. '{$2=$2-1; print $1,$2".0"}')
GPU_NODE=$(oc get node --no-headers | grep -v "control-plane" | head -1 | awk '{print $1}')
IDS=$(oc debug node/"${GPU_NODE}" -n default -- chroot /host/ bash -c 'lspci -nnv' | grep -i nvidia | head -n 1 | sed -n 's/.*\[\(.*:[0-9a-f]*\)\].*/\1/p')

cat <<EOF >> "/tmp/100-worker-iommu.bu"
variant: openshift
version: ${VERSION}
metadata:
  name: 100-worker-iommu
  labels:
    machineconfiguration.openshift.io/role: worker
openshift:
  kernel_arguments:
    - intel_iommu=on
EOF

cat <<EOF >> "/tmp/100-worker-vfiopci.bu"
variant: openshift
version: ${VERSION}
metadata:
  name: 100-worker-vfiopci
  labels:
    machineconfiguration.openshift.io/role: worker
storage:
  files:
  - path: /etc/modprobe.d/vfio.conf
    mode: 0644
    overwrite: true
    contents:
      inline: |
        options vfio-pci ids=${IDS}
  - path: /etc/modules-load.d/vfio-pci.conf
    mode: 0644
    overwrite: true
    contents:
      inline: vfio-pci
EOF

/tmp/butane /tmp/100-worker-vfiopci.bu > /tmp/100-worker-vfiopci.yaml
/tmp/butane /tmp/100-worker-iommu.bu > /tmp/100-worker-iommu.yaml

oc apply -f /tmp/100-worker-vfiopci.yaml && oc apply -f /tmp/100-worker-iommu.yaml

sleep 120
oc wait --all --for=condition=Updated=True machineconfigpool --timeout=60m
oc wait --all --for=condition=Available=True clusteroperators.config.openshift.io --timeout=20m

GPU_NAME=$(oc debug node/"${GPU_NODE}" -n default -- chroot /host/ bash -c 'lspci -nnv' | grep -i nvidia | head -n 1 | awk -F': ' '{print $2}' | awk '{print $3 "_" $4 "_" $5}' | sed 's/\[\|\]//g')
oc patch HyperConverged -n openshift-cnv kubevirt-hyperconverged --type merge --patch '{"spec":{"permittedHostDevices":{"pciHostDevices":[{"pciDeviceSelector": "'"${IDS}"'", "resourceName": "'"nvidia.com/${GPU_NAME}"'"}]}}}'
echo "nvidia.com/$GPU_NAME" > "${SHARED_DIR}/GPU_DEVICE_NAME"
cp -f /tmp/100-worker-iommu.yaml "${ARTIFACT_DIR}/100-worker-iommu.yaml"
cp -f /tmp/100-worker-vfiopci.yaml "${ARTIFACT_DIR}/100-worker-vfiopci.yaml"