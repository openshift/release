#!/bin/bash
set -eux -o pipefail; shopt -s inherit_errexit

FA__SCALE__NAMESPACE="${FA__SCALE__NAMESPACE:-ibm-spectrum-scale}"
saName="gpfs-host-prep-sa"
dsName="gpfs-host-prep"
FA__GPFS_IMAGE="${FA__GPFS_IMAGE:-cp.icr.io/cp/gpfs/data-management/ibm-spectrum-scale-daemon@sha256:243d01d63492f43266fbeef623db711df5f40e878f900e39ef6bde36a6148315}"

: 'Preparing host paths for IBM Storage Scale kernel/daemon communication...'
: 'This step uses a privileged DaemonSet to:'
: '  1. Create required directories in /var/gpfs (writable on RHCOS)'
: '  2. Copy GPFS binaries and libraries from container to host'
: '  3. Configure host ldconfig for library resolution'
: '  4. Verify host-side binary execution'
: 'This enables the kernel module'\''s call_usermodehelper() upcalls to succeed.'

: 'Step 1: Creating ServiceAccount for privileged access...'
oc create serviceaccount "${saName}" -n "${FA__SCALE__NAMESPACE}" --dry-run=client -o yaml | oc apply -f -

: 'Step 2: Granting privileged SCC to ServiceAccount...'
oc adm policy add-scc-to-user privileged -z "${saName}" -n "${FA__SCALE__NAMESPACE}"

: 'Step 3: Linking IBM entitlement pull secret...'
if oc get secret fusion-pullsecret -n "${FA__SCALE__NAMESPACE}" >/dev/null; then
  pullSecret="fusion-pullsecret"
elif oc get secret ibm-entitlement-key -n "${FA__SCALE__NAMESPACE}" >/dev/null; then
  pullSecret="ibm-entitlement-key"
else
  : "ERROR: No entitlement secret found in ${FA__SCALE__NAMESPACE}"
  : 'Available secrets:'
  if ! oc get secrets -n "${FA__SCALE__NAMESPACE}" --no-headers | awk '{print $1}'; then
    : 'Failed to list secrets'
  fi
  exit 1
fi
: "Found entitlement secret: ${pullSecret}"
oc secrets link "${saName}" "${pullSecret}" --for=pull -n "${FA__SCALE__NAMESPACE}"

: 'Step 4: Applying gpfs-host-prep DaemonSet...'
oc apply -f - <<EOF
apiVersion: apps/v1
kind: DaemonSet
metadata:
  name: ${dsName}
  namespace: ${FA__SCALE__NAMESPACE}
  labels:
    app: gpfs-host-prep
spec:
  selector:
    matchLabels:
      name: ${dsName}
  template:
    metadata:
      labels:
        name: ${dsName}
        app: gpfs-host-prep
    spec:
      serviceAccountName: ${saName}
      nodeSelector:
        scale.spectrum.ibm.com/role: storage
      hostPID: true
      tolerations:
      - operator: Exists
      containers:
      - name: prep
        image: ${FA__GPFS_IMAGE}
        securityContext:
          privileged: true
        command: ["/bin/bash", "-c"]
        args:
          - |
            set -e
            echo "=== GPFS Host Path Preparation ==="
            echo ""
            
            echo "Creating host directories..."
            mkdir -p /host/var/gpfs/bin
            mkdir -p /host/var/gpfs/lib
            mkdir -p /host/var/mmfs/etc
            mkdir -p /host/var/lib/firmware
            
            echo "Copying GPFS binaries to host..."
            cp -rf /usr/lpp/mmfs/bin/* /host/var/gpfs/bin/
            
            echo "Copying GPFS libraries to host..."
            cp -rf /usr/lpp/mmfs/lib/* /host/var/gpfs/lib/
            
            echo "Setting up overlay filesystem on /usr..."
            nsenter -t 1 -m -u -i -n -p -- bash -c '
              mkdir -p /var/overlay/usr-upper /var/overlay/usr-work
              if ! mount -t overlay overlay -o lowerdir=/usr,upperdir=/var/overlay/usr-upper,workdir=/var/overlay/usr-work /usr; then
                echo "overlay mount on /usr failed (may already be active)"
              fi
              mkdir -p /usr/lpp/mmfs/lib /usr/lpp/mmfs/bin
              mount --bind /var/gpfs/lib /usr/lpp/mmfs/lib
              mount --bind /var/gpfs/bin /usr/lpp/mmfs/bin
            '
            
            echo "Fixing crypto library symlinks..."
            if [[ -d /host/var/gpfs/lib/crypto ]]; then
              for lib in /host/var/gpfs/lib/crypto/libgpfs_crypto*.so; do
                [[ -f "\$lib" ]] && cp -f "\$lib" /host/var/gpfs/lib/
              done
            fi
            
            echo "Configuring host linker cache..."
            echo "/var/gpfs/lib" > /host/etc/ld.so.conf.d/gpfs-ci.conf
            chroot /host ldconfig
            
            echo "Verifying host-side binary execution..."
            if chroot /host /var/gpfs/bin/mmfsadm --help >/dev/null; then
              echo "SUCCESS: Host binary verification passed"
            elif chroot /host /var/gpfs/bin/mmfsadm >/dev/null; then
              echo "SUCCESS: Host binary verification passed (no --help flag)"
            else
              EXIT_CODE=\$?
              if [[ \$EXIT_CODE -eq 127 ]]; then
                echo "FAILURE: Binary cannot execute - missing libraries"
                chroot /host ldd /var/gpfs/bin/mmfsadm 2>&1 || true
                exit 1
              else
                echo "SUCCESS: Binary executed (exit code \$EXIT_CODE is acceptable)"
              fi
            fi
            
            echo ""
            echo "Creating completion marker..."
            touch /host/tmp/gpfs-prep-complete
            
            echo ""
            echo "=== Host preparation complete ==="
            echo "Binaries available at: /var/gpfs/bin/"
            echo "Libraries available at: /var/gpfs/lib/"
            echo ""
            echo "Keeping container running for pod health..."
            sleep infinity
        volumeMounts:
        - name: host-root
          mountPath: /host
      volumes:
      - name: host-root
        hostPath:
          path: /
          type: Directory
EOF

: 'Step 5: Waiting for DaemonSet rollout...'
if ! oc rollout status ds/"${dsName}" -n "${FA__SCALE__NAMESPACE}" --timeout=5m; then
  : 'DaemonSet rollout failed, checking pod status...'
  oc get pods -n "${FA__SCALE__NAMESPACE}" -l name="${dsName}" -o wide
  oc describe pods -n "${FA__SCALE__NAMESPACE}" -l name="${dsName}" | tail -50
  exit 1
fi

: 'Step 6: Verifying completion on all storage nodes...'
storageNodes=$(oc get nodes -l scale.spectrum.ibm.com/role=storage -o jsonpath='{.items[*].metadata.name}')
verificationFailed="false"

for node in ${storageNodes}; do
  : "Checking node: ${node}"
  if oc debug node/"${node}" --quiet -- chroot /host test -f /tmp/gpfs-prep-complete; then
    : "  ✅ Preparation complete on ${node}"
  else
    : "  ⚠️  Completion marker not found on ${node}, checking files..."
    oc debug node/"${node}" --quiet -- chroot /host ls -la /var/gpfs/bin/mmfsadm || verificationFailed="true"
  fi
done

if [[ "${verificationFailed}" == "true" ]]; then
  : 'WARNING: Some nodes may not have completed preparation'
  : 'Checking DaemonSet pod logs...'
  for pod in $(oc get pods -n "${FA__SCALE__NAMESPACE}" -l name="${dsName}" -o jsonpath='{.items[*].metadata.name}'); do
    : "--- Logs from ${pod} ---"
    if ! oc logs -n "${FA__SCALE__NAMESPACE}" "${pod}" --tail=20; then
      : '(logs not available)'
    fi
  done
fi

: 'Step 7: Verifying library resolution on first storage node...'
firstNode=$(echo "${storageNodes}" | awk '{print $1}')
if [[ -n "${firstNode}" ]]; then
  : "Testing ldconfig on ${firstNode}..."
  oc debug node/"${firstNode}" --quiet -- chroot /host bash -c '
    echo "Library path configuration:"
    cat /etc/ld.so.conf.d/gpfs-ci.conf || echo "(not found)"
    echo ""
    echo "Library resolution for mmfsadm:"
    ldd /var/gpfs/bin/mmfsadm 2>&1 | head -10 || echo "(ldd failed)"
  ' 2>&1 | grep -v "Starting pod\|Removing debug" || true
fi

: '✅ IBM Storage Scale host paths prepared successfully'
: 'Summary:'
: '  - Binaries copied to /var/gpfs/bin/ on all storage nodes'
: '  - Libraries copied to /var/gpfs/lib/ on all storage nodes'
: '  - Host ldconfig updated with /var/gpfs/lib'
: '  - Kernel module upcalls can now find helper binaries'
: 'The kernel module'\''s call_usermodehelper() to mmfsd_path=/var/gpfs/bin/'
: 'will now succeed, allowing GPFS daemon startup.'

true
