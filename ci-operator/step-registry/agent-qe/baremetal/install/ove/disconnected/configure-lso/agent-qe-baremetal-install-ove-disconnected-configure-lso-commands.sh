#!/bin/bash
set -euo pipefail

function set_proxy () {
    if test -s "${SHARED_DIR}/proxy-conf.sh" ; then
        echo "setting the proxy"
        echo "source ${SHARED_DIR}/proxy-conf.sh"
        source "${SHARED_DIR}/proxy-conf.sh"
        export no_proxy=brew.registry.redhat.io,registry.stage.redhat.io,registry.redhat.io,registry.ci.openshift.org,quay.io,s3.us-east-1.amazonaws.com
        export NO_PROXY=brew.registry.redhat.io,registry.stage.redhat.io,registry.redhat.io,registry.ci.openshift.org,quay.io,s3.us-east-1.amazonaws.com
    else
        echo "no proxy setting."
    fi
}

set_proxy

echo "Labeling all nodes with localstorage=enabled..."
oc label nodes --all localstorage=enabled --overwrite

echo "Creating MachineConfig for loop device..."
cat <<EOF | oc apply -f -
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
    systemd:
      units:
        - name: loop10-mon.service
          enabled: true
          contents: |
            [Unit]
            Description=Create loop device for Ceph MON
            After=local-fs.target
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
oc wait mcp/master --for=condition=Updating --timeout=5m

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

echo "Creating LocalVolumeSet for block storage..."
cat <<EOF | oc apply -f -
apiVersion: local.storage.openshift.io/v1alpha1
kind: LocalVolumeSet
metadata:
  name: localvolumeset
  namespace: openshift-local-storage
spec:
  storageClassName: localblock
  volumeMode: Block
  fsType: xfs
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
      - disk
    minSize: 100Gi
EOF

echo "Waiting for localblock storage class to be created..."
COUNTER=0
while [ $COUNTER -lt 300 ]; do
    if oc get storageclass localblock &>/dev/null; then
        echo "Storage class localblock created successfully"
        break
    fi
    sleep 5
    COUNTER=$((COUNTER + 5))
    echo "Waiting ${COUNTER}s for localblock storage class..."
done

if [ $COUNTER -ge 300 ]; then
    echo "ERROR: Storage class localblock was not created within timeout"
    oc get storageclass
    exit 1
fi

echo "Local storage configuration completed successfully!"
