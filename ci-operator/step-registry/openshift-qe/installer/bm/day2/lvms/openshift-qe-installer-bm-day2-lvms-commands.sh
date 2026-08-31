#!/bin/bash
set -euo pipefail

if test -f "${SHARED_DIR}/proxy-conf.sh"; then
  # shellcheck disable=SC1090
  source "${SHARED_DIR}/proxy-conf.sh"
fi

OCP_VERSION=$(oc get clusterversion --no-headers | grep -oE '[0-9]+\.[0-9]+' | head -1)
echo "OCP version: ${OCP_VERSION}"
OCP_MAJOR=$(echo "${OCP_VERSION}" | cut -d. -f1)
OCP_MINOR=$(echo "${OCP_VERSION}" | cut -d. -f2)

if [ "${OCP_MAJOR}" -ge 5 ] || [ "${OCP_MINOR}" -ge 20 ]; then
  NAMESPACE="openshift-lvm-storage"
else
  NAMESPACE="openshift-storage"
fi
echo "LVMS namespace: ${NAMESPACE}"

ODF_CHECK=$(oc get storagecluster -n openshift-storage -o name 2>/dev/null || true)
if [ -n "${ODF_CHECK}" ]; then
  echo "ERROR: ODF StorageCluster detected. LVMS and ODF cannot share disks."
  exit 1
fi
echo "No ODF detected, proceeding with LVMS"

SSH_ARGS="-i ${CLUSTER_PROFILE_DIR}/jh_priv_ssh_key -oStrictHostKeyChecking=no -oUserKnownHostsFile=/dev/null"
INNER_SSH_ARGS="-oStrictHostKeyChecking=no -oUserKnownHostsFile=/dev/null"

wipe_nvme() {
  local bastion=$1
  ssh ${SSH_ARGS} root@${bastion} '
    for i in $(oc get node --no-headers -l node-role.kubernetes.io/worker --output custom-columns="NAME:.status.addresses[0].address"); do
      for j in {0..7}; do
        ssh -t '"${INNER_SSH_ARGS}"' core@$i "test -b /dev/nvme${j}n1 && sudo sgdisk --zap-all /dev/nvme${j}n1 && sudo wipefs -a /dev/nvme${j}n1 || true" 2>/dev/null
      done
    done'
}

wipe_sata() {
  local bastion=$1
  ssh ${SSH_ARGS} root@${bastion} '
    for i in $(oc get node --no-headers -l node-role.kubernetes.io/worker --output custom-columns="NAME:.status.addresses[0].address"); do
      for d in sdb sdc sdd sde sdf sdg sdh; do
        ssh -t '"${INNER_SSH_ARGS}"' core@$i "lsblk /dev/$d -no MOUNTPOINT 2>/dev/null | grep -q . || { sudo sgdisk --zap-all /dev/$d 2>/dev/null; sudo wipefs -a /dev/$d 2>/dev/null; } || true" 2>/dev/null
      done
    done'
}

if [ "${LVM_DEVICE_PATHS}" = "auto" ]; then
  bastion=$(cat "${CLUSTER_PROFILE_DIR}/address")
  echo "Wiping ${LVM_DISK_TYPE} disks..."
  case "${LVM_DISK_TYPE}" in
    nvme) wipe_nvme "${bastion}" ;;
    sata) wipe_sata "${bastion}" ;;
    all)  wipe_nvme "${bastion}"; wipe_sata "${bastion}" ;;
    *)    echo "ERROR: LVM_DISK_TYPE must be 'nvme', 'sata', or 'all'"; exit 1 ;;
  esac
  echo "Disk wipe complete"
else
  IFS=',' read -ra DEVICES <<< "${LVM_DEVICE_PATHS}"
  for node in $(oc get nodes -l node-role.kubernetes.io/worker -o jsonpath='{.items[*].metadata.name}'); do
    WIPE_CMD=""
    for d in "${DEVICES[@]}"; do
      WIPE_CMD="${WIPE_CMD} wipefs -a ${d} 2>/dev/null; dd if=/dev/zero of=${d} bs=1M count=100 2>/dev/null;"
    done
    oc debug "node/${node}" -- chroot /host bash -c "${WIPE_CMD}" 2>/dev/null || true
  done
fi

# Install LVMS operator
echo "Creating catalog source for LVMS v${LVM_OPERATOR_CHANNEL}"
cat <<EOF | oc apply -f -
apiVersion: operators.coreos.com/v1alpha1
kind: CatalogSource
metadata:
  name: lvms-catalog
  namespace: openshift-marketplace
spec:
  sourceType: grpc
  image: registry.redhat.io/redhat/redhat-operator-index:v${LVM_OPERATOR_CHANNEL}
  displayName: LVMS Catalog v${LVM_OPERATOR_CHANNEL}
  publisher: Red Hat
EOF

echo "Waiting for lvms-operator package..."
for i in $(seq 1 30); do
  oc get packagemanifest lvms-operator 2>/dev/null | grep -q lvms && break
  [ "$i" -eq 30 ] && { echo "ERROR: lvms-operator not found"; exit 1; }
  sleep 10
done

oc create ns "${NAMESPACE}" 2>/dev/null || true

cat <<EOF | oc apply -f -
apiVersion: operators.coreos.com/v1
kind: OperatorGroup
metadata:
  name: lvms-operatorgroup
  namespace: ${NAMESPACE}
spec:
  targetNamespaces:
  - ${NAMESPACE}
---
apiVersion: operators.coreos.com/v1alpha1
kind: Subscription
metadata:
  name: lvms-operator
  namespace: ${NAMESPACE}
spec:
  channel: "stable-${LVM_OPERATOR_CHANNEL}"
  installPlanApproval: Automatic
  name: lvms-operator
  source: lvms-catalog
  sourceNamespace: openshift-marketplace
EOF

for i in $(seq 1 60); do
  if oc get csv -n "${NAMESPACE}" 2>/dev/null | grep -q "lvms.*Succeeded"; then
    echo "LVMS operator installed"
    break
  fi
  [ "$i" -eq 60 ] && { echo "ERROR: LVMS operator not ready"; oc get csv -n "${NAMESPACE}"; exit 1; }
  sleep 5
done

# Create LVMCluster
if [ "${LVM_DEVICE_PATHS}" = "auto" ]; then
  cat <<EOF | oc apply -f -
apiVersion: lvm.topolvm.io/v1alpha1
kind: LVMCluster
metadata:
  name: lvms-cluster
  namespace: ${NAMESPACE}
spec:
  storage:
    deviceClasses:
    - name: ${LVM_VG_NAME}
      default: true
      thinPoolConfig:
        name: thin-pool
        sizePercent: 90
        overprovisionRatio: 10
      nodeSelector:
        nodeSelectorTerms:
        - matchExpressions:
          - key: node-role.kubernetes.io/worker
            operator: Exists
EOF
else
  PATHS_YAML=""
  for d in "${DEVICES[@]}"; do
    PATHS_YAML="${PATHS_YAML}
        - ${d}"
  done

  cat <<EOF | oc apply -f -
apiVersion: lvm.topolvm.io/v1alpha1
kind: LVMCluster
metadata:
  name: lvms-cluster
  namespace: ${NAMESPACE}
spec:
  storage:
    deviceClasses:
    - name: ${LVM_VG_NAME}
      default: true
      thinPoolConfig:
        name: thin-pool
        sizePercent: 90
        overprovisionRatio: 10
      deviceSelector:
        forceWipeDevicesAndDestroyAllData: true
        paths:${PATHS_YAML}
      nodeSelector:
        nodeSelectorTerms:
        - matchExpressions:
          - key: node-role.kubernetes.io/worker
            operator: Exists
EOF
fi

for i in $(seq 1 120); do
  status=$(oc get lvmcluster lvms-cluster -n "${NAMESPACE}" -o jsonpath='{.status.state}' 2>/dev/null)
  [ "$status" = "Ready" ] && { echo "LVMCluster is Ready"; break; }
  [ "$i" -eq 120 ] && { echo "ERROR: LVMCluster not ready"; oc get lvmcluster lvms-cluster -n "${NAMESPACE}" -o yaml | tail -30; exit 1; }
  sleep 5
done

echo "StorageClass: lvms-${LVM_VG_NAME}"
oc get sc | grep lvms
oc get volumesnapshotclass 2>/dev/null | grep lvms || true
