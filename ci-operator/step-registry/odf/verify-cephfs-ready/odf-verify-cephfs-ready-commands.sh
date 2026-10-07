#!/usr/bin/env bash

# Fail the job (before any storage-dependent test runs) when ODF CephFS RWX storage
# is not actually usable. odf-apply-storage-cluster only waits for the StorageCluster
# Available condition (or OSD readiness); that can be satisfied while the CephFS CSI
# driver is still down, which later surfaces only as per-test MountDevice timeouts
# ("cephfs.csi.ceph.com/csi.sock: connection refused", unbound PVCs) and a confusing
# cluster-wide red run. Verify the specific capability storage-based-remediation needs:
# the CephFS CSI plugin is Ready and a ReadWriteMany PVC actually binds.

set -euo pipefail

NS="${ODF__INSTALL_NAMESPACE}"

echo "INFO: Verifying CephFS CSI plugin pods are Ready in ${NS}"
if ! oc rollout status daemonset/csi-cephfsplugin -n "${NS}" \
    --timeout="${ODF__CEPHFS_CSI_WAIT_TIMEOUT}"; then
    echo "ERROR: CephFS CSI node plugin (daemonset/csi-cephfsplugin) is not Ready in ${NS}." >&2
    echo "ODF reports the StorageCluster up but CephFS CSI is unavailable; failing before tests run." >&2
    oc get pods -n "${NS}" -l app=csi-cephfsplugin -o wide >&2 || true
    exit 1
fi

echo "INFO: Discovering a CephFS StorageClass"
CEPHFS_SC="$(oc get storageclass -o jsonpath='{range .items[?(@.provisioner=="'"${NS}"'.cephfs.csi.ceph.com")]}{.metadata.name}{"\n"}{end}' | head -1)"
if [[ -z "${CEPHFS_SC}" ]]; then
    echo "ERROR: No CephFS-backed StorageClass found (provisioner ${NS}.cephfs.csi.ceph.com)." >&2
    oc get storageclass >&2 || true
    exit 1
fi
echo "INFO: Using CephFS StorageClass ${CEPHFS_SC}"

# End-to-end capability check: a real RWX PVC must bind within the timeout. This catches
# a provisioner that is up but not actually servicing requests. Use a unique namespace per
# invocation so concurrent runs cannot collide on create or delete each other's namespace
# in the cleanup trap.
PVC_NS="verify-cephfs-${RANDOM}${RANDOM}"
PVC_NAME="cephfs-readiness-probe"

cleanup() {
    oc delete namespace "${PVC_NS}" --ignore-not-found --wait=false >/dev/null 2>&1 || true
}
trap cleanup EXIT

oc create namespace "${PVC_NS}" --dry-run=client -o yaml | oc apply -f - >/dev/null

echo "INFO: Creating a ReadWriteMany PVC to confirm CephFS provisioning works"
oc apply -f - <<EOF >/dev/null
apiVersion: v1
kind: PersistentVolumeClaim
metadata:
  name: ${PVC_NAME}
  namespace: ${PVC_NS}
spec:
  accessModes:
    - ReadWriteMany
  resources:
    requests:
      storage: 1Gi
  storageClassName: ${CEPHFS_SC}
EOF

if ! oc wait "pvc/${PVC_NAME}" -n "${PVC_NS}" \
    --for=jsonpath='{.status.phase}'=Bound \
    --timeout="${ODF__CEPHFS_PVC_BIND_TIMEOUT}"; then
    echo "ERROR: CephFS RWX PVC did not bind within ${ODF__CEPHFS_PVC_BIND_TIMEOUT}." >&2
    echo "CephFS provisioning is not functional; failing before storage-dependent tests run." >&2
    oc describe "pvc/${PVC_NAME}" -n "${PVC_NS}" >&2 || true
    exit 1
fi

echo "INFO: CephFS is healthy — CSI plugin Ready and RWX PVC bound."
