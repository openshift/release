#!/bin/bash
set -euo pipefail

if [ -f "${SHARED_DIR}/proxy-conf.sh" ] ; then
    source "${SHARED_DIR}/proxy-conf.sh"
fi

echo "Labeling all nodes with localstorage=enabled..."
oc label nodes --all localstorage=enabled --overwrite

echo "Creating MachineConfig for disk wipe and loop device..."
cat <<'EOF' | oc apply -f -
apiVersion: machineconfiguration.openshift.io/v1
kind: MachineConfig
metadata:
  name: 99-local-storage-loop-and-osd
  labels:
    machineconfiguration.openshift.io/role: master
spec:
  config:
    ignition:
      version: 3.2.0
    storage:
      files:
        - path: /usr/local/bin/wipe-osd-disks.sh
          mode: 0755
          overwrite: true
          contents:
            source: data:text/plain;charset=utf-8;base64,IyEvYmluL2Jhc2gKIyBXaXBlIGFsbCBub24tT1MgZGlza3MgPj0gMTAwR2lCIHRvIHJlbW92ZSBzdGFsZSBDZXBoIEJsdWVTdG9yZSBtZXRhZGF0YS4KIyBSdW5zIGFzIGEgc3lzdGVtZCBvbmVzaG90IGJlZm9yZSBLdWJlcm5ldGVzIHdvcmtsb2FkcyB0b3VjaCB0aGUgZGlza3MuCk1JTl9CWVRFUz0kKCgxMDAgKiAxMDI0ICogMTAyNCAqIDEwMjQpKQpXSVBFRD0wCmZvciBERVYgaW4gJChsc2JsayAtZG5vIE5BTUUsVFlQRSxTSVpFIC0tYnl0ZXMgMj4vZGV2L251bGwgfCBhd2sgLXYgbWluPSIke01JTl9CWVRFU30iICckMj09ImRpc2siICYmICQzPj1taW4ge3ByaW50ICQxfScpOyBkbwogIE1PVU5UUz0kKGxzYmxrIC1ubyBNT1VOVFBPSU5UICIvZGV2LyR7REVWfSIgMj4vZGV2L251bGwgfCBncmVwIC12ICdeJCcgfHwgdHJ1ZSkKICBpZiBbIC1uICIke01PVU5UU30iIF07IHRoZW4KICAgIGVjaG8gIndpcGUtb3NkLWRpc2tzOiBTa2lwcGluZyAvZGV2LyR7REVWfSAoaGFzIGFjdGl2ZSBtb3VudHMpIgogICAgY29udGludWUKICBmaQogIGVjaG8gIndpcGUtb3NkLWRpc2tzOiBXaXBpbmcgL2Rldi8ke0RFVn0iCiAgd2lwZWZzIC1hZiAiL2Rldi8ke0RFVn0iIDI+JjEgfHwgdHJ1ZQogIHNnZGlzayAtLXphcC1hbGwgIi9kZXYvJHtERVZ9IiAyPiYxIHx8IHRydWUKICBkZCBpZj0vZGV2L3plcm8gb2Y9Ii9kZXYvJHtERVZ9IiBicz0xTSBjb3VudD0yMDAgY29udj1mc3luYyAyPi9kZXYvbnVsbCB8fCB0cnVlCiAgRElTS19NQj0kKCggJChibG9ja2RldiAtLWdldHNpemU2NCAiL2Rldi8ke0RFVn0iKSAvIDEwNDg1NzYgKSkKICBpZiBbICR7RElTS19NQn0gLWd0IDQwMCBdOyB0aGVuCiAgICBkZCBpZj0vZGV2L3plcm8gb2Y9Ii9kZXYvJHtERVZ9IiBicz0xTSBjb3VudD0yMDAgc2Vlaz0kKCggRElTS19NQiAtIDIwMCApKSBjb252PWZzeW5jIDI+L2Rldi9udWxsIHx8IHRydWUKICBmaQogIGVjaG8gIndpcGUtb3NkLWRpc2tzOiAvZGV2LyR7REVWfSB3aXBlZCIKICBXSVBFRD0kKChXSVBFRCArIDEpKQpkb25lCmVjaG8gIndpcGUtb3NkLWRpc2tzOiAke1dJUEVEfSBkaXNrKHMpIHByb2Nlc3NlZCIK
    systemd:
      units:
        - name: wipe-osd-disks.service
          enabled: true
          contents: |
            [Unit]
            Description=Wipe stale Ceph/OSD signatures from secondary disks
            After=local-fs.target
            Before=loop10-mon.service kubelet.service

            [Service]
            Type=oneshot
            ExecStart=/usr/local/bin/wipe-osd-disks.sh
            RemainAfterExit=yes

            [Install]
            WantedBy=multi-user.target
        - name: loop10-mon.service
          enabled: true
          contents: |
            [Unit]
            Description=Create loop device for Ceph MON
            After=local-fs.target wipe-osd-disks.service
            Wants=local-fs.target

            [Service]
            Type=oneshot
            ExecStartPre=/usr/bin/mkdir -p /var/lib/rook
            ExecStart=/usr/bin/dd if=/dev/zero of=/var/lib/rook/mon-loop.img bs=1M count=61440
            ExecStartPost=/usr/sbin/losetup /dev/loop10 /var/lib/rook/mon-loop.img
            RemainAfterExit=yes

            [Install]
            WantedBy=multi-user.target
EOF

echo "Waiting for master MachineConfigPool to start updating..."
oc wait mcp/master --for=condition=Updating --timeout=5m || true

echo "Waiting for master MachineConfigPool to finish updating..."
oc wait mcp/master --for=condition=Updated --timeout=1h

echo "MachineConfig applied successfully. Creating LocalVolumeSets..."

echo "Creating LocalVolumeSet for MON (loop10)..."
cat <<EOF | oc apply -f -
apiVersion: local.storage.openshift.io/v1alpha1
kind: LocalVolumeSet
metadata:
  name: localvolumeset-mon
  namespace: openshift-local-storage
spec:
  storageClassName: localblock-mon
  volumeMode: Filesystem
  maxDeviceCount: 1
  nodeSelector:
    nodeSelectorTerms:
      - matchExpressions:
          - key: localstorage
            operator: In
            values:
              - "enabled"
  deviceInclusionSpec:
    deviceTypes:
      - loop
EOF

echo "Waiting for localblock-mon storage class to be created..."
COUNTER=0
while [ $COUNTER -lt 300 ]; do
    if oc get storageclass localblock-mon &>/dev/null; then
        echo "Storage class localblock-mon created successfully"
        break
    fi
    sleep 5
    COUNTER=$((COUNTER + 5))
    echo "Waiting ${COUNTER}s for localblock-mon storage class..."
done

if [ $COUNTER -ge 300 ]; then
    echo "ERROR: Storage class localblock-mon was not created within timeout"
    oc get storageclass
    exit 1
fi

echo "Waiting for 3 PVs with localblock-mon storage class to be created..."
COUNTER=0
while [ $COUNTER -lt 600 ]; do
    PV_COUNT=$(oc get pv -o json | jq -r '[.items[] | select(.spec.storageClassName == "localblock-mon")] | length' 2>/dev/null || echo "0")
    echo "Found ${PV_COUNT} PVs with localblock-mon storage class"

    if [ "${PV_COUNT}" -ge 3 ]; then
        echo "Required 3 PVs with localblock-mon storage class are available"
        oc get pv -o wide | grep localblock-mon || true
        break
    fi

    sleep 10
    COUNTER=$((COUNTER + 10))
    echo "Waiting ${COUNTER}s for PVs to be created (need 3, found ${PV_COUNT})..."
done

if [ $COUNTER -ge 600 ]; then
    echo "ERROR: Required 3 PVs with localblock-mon storage class were not created within timeout"
    echo "Current PV status:"
    oc get pv -o wide
    echo "LocalVolumeSet status:"
    oc get localvolumeset -n openshift-local-storage localvolumeset-mon -o yaml
    echo "Pod status in openshift-local-storage:"
    oc get pods -n openshift-local-storage
    exit 1
fi

echo "Creating LocalVolumeSet for OSD (physical block devices)..."
cat <<EOF | oc apply -f -
apiVersion: local.storage.openshift.io/v1alpha1
kind: LocalVolumeSet
metadata:
  name: localvolumeset-osd
  namespace: openshift-local-storage
spec:
  storageClassName: localblock-sc
  volumeMode: Block
  nodeSelector:
    nodeSelectorTerms:
      - matchExpressions:
          - key: localstorage
            operator: In
            values:
              - "enabled"
  deviceInclusionSpec:
    deviceTypes:
      - disk
    minSize: 100Gi
EOF

echo "Waiting for localblock-sc storage class to be created..."
COUNTER=0
while [ $COUNTER -lt 300 ]; do
    if oc get storageclass localblock-sc &>/dev/null; then
        echo "Storage class localblock-sc created successfully"
        break
    fi
    sleep 5
    COUNTER=$((COUNTER + 5))
    echo "Waiting ${COUNTER}s for localblock-sc storage class..."
done

if [ $COUNTER -ge 300 ]; then
    echo "ERROR: Storage class localblock-sc was not created within timeout"
    oc get storageclass
    oc get localvolumeset -n openshift-local-storage localvolumeset-osd -o yaml
    exit 1
fi

echo "Waiting for 3 PVs with localblock-sc storage class to be created..."
COUNTER=0
while [ $COUNTER -lt 600 ]; do
    PV_COUNT=$(oc get pv -o json | jq -r '[.items[] | select(.spec.storageClassName == "localblock-sc")] | length' 2>/dev/null || echo "0")
    echo "Found ${PV_COUNT} PVs with localblock-sc storage class"

    if [ "${PV_COUNT}" -ge 3 ]; then
        echo "Required 3 PVs with localblock-sc storage class are available"
        oc get pv -o wide | grep localblock-sc || true
        break
    fi

    sleep 10
    COUNTER=$((COUNTER + 10))
    echo "Waiting ${COUNTER}s for PVs to be created (need 3, found ${PV_COUNT})..."
done

if [ $COUNTER -ge 600 ]; then
    echo "ERROR: Required 3 PVs with localblock-sc storage class were not created within timeout"
    echo "Current PV status:"
    oc get pv -o wide
    echo "LocalVolumeSet status:"
    oc get localvolumeset -n openshift-local-storage localvolumeset-osd -o yaml
    echo "Pod status in openshift-local-storage:"
    oc get pods -n openshift-local-storage
    exit 1
fi

echo "Local storage configuration completed successfully!"
echo "Available storage classes:"
oc get storageclass
echo "Available PVs:"
oc get pv -o wide
