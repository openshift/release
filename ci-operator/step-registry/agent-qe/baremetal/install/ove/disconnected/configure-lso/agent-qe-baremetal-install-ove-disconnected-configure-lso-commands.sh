#!/bin/bash
set -euo pipefail

if [ -f "${SHARED_DIR}/proxy-conf.sh" ] ; then
    source "${SHARED_DIR}/proxy-conf.sh"
fi

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

echo "=== Wiping stale signatures from OSD-candidate disks ==="
MIN_SIZE_BYTES=$((100 * 1024 * 1024 * 1024))
NODES=$(oc get nodes -l localstorage=enabled -o jsonpath='{.items[*].metadata.name}')
ZAP_IDX=0
for NODE in ${NODES}; do
    echo "--- Launching disk-zap-${ZAP_IDX} on ${NODE} ---"
    ZAP_POD="disk-zap-${ZAP_IDX}"

    cat <<ZAPEOF | oc apply -f -
apiVersion: v1
kind: Pod
metadata:
  name: ${ZAP_POD}
  namespace: openshift-local-storage
spec:
  nodeSelector:
    kubernetes.io/hostname: ${NODE}
  hostPID: true
  containers:
  - name: zap
    image: image-registry.openshift-image-registry.svc:5000/openshift/cli:latest
    command: ["/bin/bash", "-c"]
    args:
    - |
      set -uo pipefail
      MIN_BYTES=${MIN_SIZE_BYTES}
      WIPED=0

      for DEV in \$(lsblk -dno NAME,TYPE,SIZE --bytes 2>/dev/null | awk -v min="\${MIN_BYTES}" '\$2=="disk" && \$3>=min {print \$1}'); do
        MOUNTS=\$(lsblk -no MOUNTPOINT "/dev/\${DEV}" 2>/dev/null | grep -v '^$' || true)
        if [[ -n "\${MOUNTS}" ]]; then
          echo "Skipping /dev/\${DEV} (has active mounts)"
          continue
        fi

        FSTYPE=\$(lsblk -dno FSTYPE "/dev/\${DEV}" 2>/dev/null || true)
        PTTYPE=\$(lsblk -dno PTTYPE "/dev/\${DEV}" 2>/dev/null || true)
        if [[ -z "\${FSTYPE}" && -z "\${PTTYPE}" ]]; then
          echo "/dev/\${DEV}: already clean"
          WIPED=\$((WIPED + 1))
          continue
        fi

        echo "/dev/\${DEV}: stale data detected (fs=\${FSTYPE:-none} pt=\${PTTYPE:-none}), wiping..."
        wipefs -af "/dev/\${DEV}" 2>&1 || echo "  wipefs unavailable, using dd"
        sgdisk --zap-all "/dev/\${DEV}" 2>&1 || true
        dd if=/dev/zero of="/dev/\${DEV}" bs=1M count=10 conv=fsync 2>/dev/null || true
        DISK_MB=\$(( \$(blockdev --getsize64 "/dev/\${DEV}") / 1048576 ))
        if [[ \${DISK_MB} -gt 20 ]]; then
          dd if=/dev/zero of="/dev/\${DEV}" bs=1M count=10 seek=\$(( DISK_MB - 10 )) conv=fsync 2>/dev/null || true
        fi
        echo "/dev/\${DEV}: wiped"
        WIPED=\$((WIPED + 1))
      done
      echo "Disks processed: \${WIPED}"
    securityContext:
      privileged: true
  restartPolicy: Never
  terminationGracePeriodSeconds: 0
ZAPEOF

    ZAP_IDX=$((ZAP_IDX + 1))
done

echo "Waiting for all disk-zap pods to complete..."
for i in $(seq 0 $((ZAP_IDX - 1))); do
    POD="disk-zap-${i}"
    if ! oc wait --for=jsonpath='{.status.phase}'=Succeeded "pod/${POD}" -n openshift-local-storage --timeout=5m 2>/dev/null; then
        echo "WARNING: ${POD} did not succeed:"
        oc logs "${POD}" -n openshift-local-storage 2>/dev/null || true
    else
        echo "${POD} completed:"
        oc logs "${POD}" -n openshift-local-storage 2>/dev/null || true
    fi
    oc delete pod "${POD}" -n openshift-local-storage --force --grace-period=0 2>/dev/null || true
done
echo "Disk wipe complete"

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
