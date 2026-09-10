#!/bin/bash
# OCPBUGS-76596 Fix Installation Step
# Installs patched kernel (RHEL-247088) + OVS (73.rhel247088) on one worker node
# Required before running the fix-validation test variant.

set -euo pipefail

export KUBECONFIG="${KUBECONFIG:-$SHARED_DIR/kubeconfig}"

OUTDIR="${ARTIFACT_DIR}/ct-flush-fix-install"
mkdir -p "$OUTDIR"

echo "================================================================"
echo " OCPBUGS-76596 Fix Installation"
echo " Kernel: RHEL-247088 backport"
echo " OVS:    3.5.2-73.el9fdp.rhel247088"
echo " Date:   $(date -u)"
echo "================================================================"

# ── Pick busiest worker node ──────────────────────────────────────
TARGET_NODE=""
BEST_FLOWS=0

for node in $(oc get nodes -l node-role.kubernetes.io/worker --no-headers \
  -o custom-columns=NAME:.metadata.name 2>/dev/null); do
  pod=$(oc get pod -n openshift-ovn-kubernetes -l app=ovnkube-node \
    --field-selector "spec.nodeName=$node" \
    -o jsonpath='{.items[0].metadata.name}' 2>/dev/null)
  [ -z "$pod" ] && continue
  flows=$(oc exec -n openshift-ovn-kubernetes "$pod" -c ovn-controller -- \
    bash -c 'ovs-ofctl dump-flows br-int | wc -l' 2>/dev/null || echo 0)
  if [ "${flows:-0}" -gt "$BEST_FLOWS" ]; then
    BEST_FLOWS=$flows; TARGET_NODE=$node; TARGET_POD=$pod
  fi
done

if [ -z "$TARGET_NODE" ]; then
  echo "ERROR: No worker node found"
  exit 1
fi
echo "Target node: $TARGET_NODE (OVN pod: $TARGET_POD, $BEST_FLOWS flows)"
echo "target_node=$TARGET_NODE" > "$OUTDIR/install-info.txt"

# ── Download RPMs ─────────────────────────────────────────────────
echo ""
echo "=== Downloading patched kernel RPMs ==="
mkdir -p /tmp/fix-rpms/{kernel,ovs}

for rpm in \
  kernel-${KERNEL_VERSION}.x86_64.rpm \
  kernel-core-${KERNEL_VERSION}.x86_64.rpm \
  kernel-modules-${KERNEL_VERSION}.x86_64.rpm \
  kernel-modules-core-${KERNEL_VERSION}.x86_64.rpm \
  kernel-modules-extra-${KERNEL_VERSION}.x86_64.rpm; do
  curl -fLo /tmp/fix-rpms/kernel/$rpm "${KERNEL_RPM_BASE_URL}/$rpm" 2>/dev/null && \
    echo "  Downloaded: $rpm" || { echo "ERROR: Failed to download $rpm"; exit 1; }
done

echo "=== Downloading patched OVS RPMs ==="
curl -fLo /tmp/fix-rpms/ovs/openvswitch3.5-${OVS_VERSION}.x86_64.rpm \
  "${OVS_RPM_BASE_URL}/openvswitch3.5-${OVS_VERSION}.x86_64.rpm" 2>/dev/null && \
  echo "  Downloaded: openvswitch3.5-${OVS_VERSION}.x86_64.rpm" || \
  { echo "ERROR: Failed to download OVS RPM"; exit 1; }

curl -fLo /tmp/fix-rpms/ovs/python3-openvswitch3.5-${OVS_VERSION}.x86_64.rpm \
  "${OVS_RPM_BASE_URL}/python3-openvswitch3.5-${OVS_VERSION}.x86_64.rpm" 2>/dev/null && \
  echo "  Downloaded: python3-openvswitch3.5-${OVS_VERSION}.x86_64.rpm" || \
  { echo "ERROR: Failed to download python3-OVS RPM"; exit 1; }

ls -lh /tmp/fix-rpms/kernel/ /tmp/fix-rpms/ovs/

# ── Copy RPMs to target node ──────────────────────────────────────
echo ""
echo "=== Copying RPMs to $TARGET_NODE ==="
for rpm in /tmp/fix-rpms/kernel/*.rpm /tmp/fix-rpms/ovs/*.rpm; do
  oc cp "$rpm" \
    "openshift-ovn-kubernetes/${TARGET_POD}:/host/var/tmp/$(basename $rpm)" \
    -c ovnkube-controller 2>/dev/null && echo "  Copied: $(basename $rpm)"
done

# ── Install kernel via rpm-ostree (persists across reboots) ───────
echo ""
echo "=== Installing patched kernel via rpm-ostree ==="
oc exec -n openshift-ovn-kubernetes "$TARGET_POD" -c ovnkube-controller -- \
  nsenter -t 1 -m -u -i -n -p -- \
  rpm-ostree override replace \
    /var/tmp/kernel-${KERNEL_VERSION}.x86_64.rpm \
    /var/tmp/kernel-core-${KERNEL_VERSION}.x86_64.rpm \
    /var/tmp/kernel-modules-${KERNEL_VERSION}.x86_64.rpm \
    /var/tmp/kernel-modules-core-${KERNEL_VERSION}.x86_64.rpm \
    /var/tmp/kernel-modules-extra-${KERNEL_VERSION}.x86_64.rpm 2>/dev/null

echo "Rebooting $TARGET_NODE..."
oc exec -n openshift-ovn-kubernetes "$TARGET_POD" -c ovnkube-controller -- \
  nsenter -t 1 -m -u -i -n -p -- systemctl reboot 2>/dev/null || true

echo "Waiting for node to come back Ready..."
sleep 30
for i in $(seq 1 20); do
  sleep 15
  STATUS=$(oc get node "$TARGET_NODE" --no-headers 2>/dev/null | awk '{print $2}')
  echo "  t+$((i*15+30))s: $STATUS"
  [ "$STATUS" = "Ready" ] && echo "Node is Ready!" && break
done

# Verify new kernel
NEW_KERNEL=$(oc get node "$TARGET_NODE" \
  -o jsonpath='{.status.nodeInfo.kernelVersion}' 2>/dev/null)
echo "Kernel after reboot: $NEW_KERNEL"
echo "kernel_installed=$NEW_KERNEL" >> "$OUTDIR/install-info.txt"

# Get new OVN pod after reboot
TARGET_POD=$(oc get pod -n openshift-ovn-kubernetes -l app=ovnkube-node \
  --field-selector "spec.nodeName=$TARGET_NODE" \
  -o jsonpath='{.items[0].metadata.name}' 2>/dev/null)
echo "New OVN pod: $TARGET_POD"
echo "target_pod=$TARGET_POD" >> "$OUTDIR/install-info.txt"

# ── Install OVS via privileged patcher pod (survives during test) ─
echo ""
echo "=== Installing patched OVS via privileged patcher pod ==="

cat <<EOF | oc apply -f - 2>/dev/null
apiVersion: v1
kind: Pod
metadata:
  name: ovs-patcher-76596
  namespace: default
spec:
  nodeName: $TARGET_NODE
  hostPID: true
  hostNetwork: true
  tolerations:
  - operator: Exists
  containers:
  - name: patcher
    image: registry.access.redhat.com/ubi9/ubi:latest
    command: ["/bin/bash", "-c", "sleep infinity"]
    securityContext:
      privileged: true
    volumeMounts:
    - name: host
      mountPath: /host
  volumes:
  - name: host
    hostPath:
      path: /
EOF

oc wait pod/ovs-patcher-76596 -n default --for=condition=Ready --timeout=60s

# Create overlay and install OVS
oc exec -n default ovs-patcher-76596 -- \
  nsenter -t 1 -m -u -i -n -p -- bash -c "
    rm -f /run/ostree-unlock 2>/dev/null || true
    mkdir -p /run/usr-overlay/{upper,work}
    mount -t overlay overlay \
      -o lowerdir=/usr,upperdir=/run/usr-overlay/upper,workdir=/run/usr-overlay/work \
      /usr 2>/dev/null || true
    rpm -Uvh --nodeps \
      /var/tmp/openvswitch3.5-${OVS_VERSION}.x86_64.rpm \
      /var/tmp/python3-openvswitch3.5-${OVS_VERSION}.x86_64.rpm
    systemctl restart openvswitch ovs-vswitchd
    sleep 3
    rpm -q openvswitch3.5
    ovs-vswitchd --version | head -1
  " 2>/dev/null

echo "OVS_installed=$(oc exec -n default ovs-patcher-76596 -- \
  nsenter -t 1 -m -u -i -n -p -- rpm -q openvswitch3.5 2>/dev/null)" \
  >> "$OUTDIR/install-info.txt"

# ── Verify CTA_FILTER_ZONE is active ─────────────────────────────
echo ""
echo "=== Verifying fix is active ==="

# Trigger a pod to force first zone flush
oc run ct-verify --image=gcr.io/google_containers/pause:3.1 \
  --overrides="{\"spec\":{\"nodeSelector\":{\"kubernetes.io/hostname\":\"$TARGET_NODE\"}}}" \
  --restart=Never -n default 2>/dev/null
sleep 20
oc delete pod ct-verify -n default --ignore-not-found 2>/dev/null

CTA_MSG=$(oc exec -n openshift-ovn-kubernetes "$TARGET_POD" -c ovnkube-controller -- \
  nsenter -t 1 -m -u -i -n -p -- \
  grep 'Conntrack flush by zone' /var/log/openvswitch/ovs-vswitchd.log 2>/dev/null | tail -1)

echo "OVS zone flush log: $CTA_MSG"

if echo "$CTA_MSG" | grep -q "CTA_FILTER_ZONE"; then
  echo "✅ Fix confirmed active: CTA_FILTER_ZONE in use"
  echo "cta_filter_zone=active" >> "$OUTDIR/install-info.txt"
else
  echo "❌ Fix NOT confirmed — CTA_FILTER_ZONE not detected"
  echo "cta_filter_zone=NOT_ACTIVE" >> "$OUTDIR/install-info.txt"
  exit 1
fi

# Save target node info to shared dir for the next step
echo "$TARGET_NODE" > "$SHARED_DIR/ct_flush_target_node"
echo "$TARGET_POD" > "$SHARED_DIR/ct_flush_ovn_pod"

echo ""
echo "================================================================"
echo " Fix installation complete. Ready for validation test."
echo " Target: $TARGET_NODE"
echo " Kernel: $NEW_KERNEL"
echo "================================================================"
