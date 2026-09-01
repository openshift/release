#!/bin/bash
# OCPBUGS-76596 CT Flush Reproduction Test
# Reproduces: "timed out waiting for OVS port binding (ovn-installed)"
# Root cause: NXT_CT_FLUSH_ZONE + large conntrack table on RHEL 9 kernel
# Fix: RHEL-247088 (kernel 6.8 zone-filter support)

set -euo pipefail

export KUBECONFIG="${KUBECONFIG:-$SHARED_DIR/kubeconfig}"

OUTDIR="${ARTIFACT_DIR}/ct-flush-repro"
mkdir -p "$OUTDIR"

KB_PID=""
LOG_PID=""
OVN_POD=""

cleanup() {
  [ -n "$LOG_PID" ] && kill "$LOG_PID" 2>/dev/null || true
  [ -n "$KB_PID" ]  && kill "$KB_PID"  2>/dev/null || true
  [ -n "$OVN_POD" ] && oc exec -n openshift-ovn-kubernetes "$OVN_POD" -- \
    nsenter -t 1 -m -u -i -n -p -- \
    ovs-appctl vlog/set vconn:file:info 2>/dev/null || true
}
trap cleanup EXIT

echo "================================================================"
echo " OCPBUGS-76596 NXT_CT_FLUSH_ZONE Reproduction Test"
echo " Date: $(date -u)"
echo "================================================================"

OCP_VER=$(oc version 2>/dev/null | grep "Server Version" | awk '{print $3}')
echo "OCP: $OCP_VER"

# ── Find busiest worker node ──────────────────────────────────────────────────
echo ""
echo "=== Finding target worker node ==="
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
  echo "  $node: $flows flows"
  if [ "${flows:-0}" -gt "$BEST_FLOWS" ]; then
    BEST_FLOWS=$flows; TARGET_NODE=$node
  fi
done

if [ -z "$TARGET_NODE" ]; then
  echo "ERROR: No worker node found"
  exit 1
fi

OVN_POD=$(oc get pod -n openshift-ovn-kubernetes -l app=ovnkube-node \
  --field-selector "spec.nodeName=$TARGET_NODE" \
  -o jsonpath='{.items[0].metadata.name}' 2>/dev/null)

echo "Target: $TARGET_NODE ($OVN_POD) — $BEST_FLOWS flows"
echo "OCP=$OCP_VER target=$TARGET_NODE flows=$BEST_FLOWS" > "$OUTDIR/info.txt"

# ── Step 1: kube-burner churn (triggers NXT_CT_FLUSH_ZONE) ─────────────────
echo ""
echo "=== Step 1: kube-burner node-density-cni with churn ==="
KB_LOG="$OUTDIR/kube-burner.log"

kube-burner-ocp node-density-cni \
  --pods-per-node="${KB_PODS_PER_NODE}" \
  --churn-cycles="${KB_CHURN_CYCLES}" \
  --churn-delay="${KB_CHURN_DELAY}" \
  --churn-percent="${KB_CHURN_PERCENT}" \
  --churn-mode=objects \
  --timeout=60m \
  --gc=false \
  --ignore-health-check \
  > "$KB_LOG" 2>&1 &
KB_PID=$!
echo "kube-burner PID: $KB_PID"

echo "Waiting 3 min for pods to deploy..."
sleep 180
echo "Pods: $(oc get pods -A --no-headers 2>/dev/null | grep density | \
  awk '{print $4}' | sort | uniq -c | head -3)"

# ── Step 2: Enable vconn debug ───────────────────────────────────────────────
echo ""
echo "=== Step 2: Enabling vconn debug ==="
oc exec -n openshift-ovn-kubernetes "$OVN_POD" -- \
  nsenter -t 1 -m -u -i -n -p -- \
  ovs-appctl vlog/set vconn:file:dbg 2>/dev/null && echo "vconn debug ON"

# ── Step 3: ct_inject.py — inject 500k CT entries ───────────────────────────
echo ""
echo "=== Step 3: Injecting $((CT_ENTRIES_PER_ZONE * 4)) conntrack entries ==="

# Write ct_inject.py directly (pure Python3 stdlib, zero dependencies)
cat > /tmp/ct_inject.py << 'PYEOF'
#!/usr/bin/env python3
"""Inject nf_conntrack entries via raw netlink. Zero dependencies."""
import socket, struct, sys, os

NETLINK_NETFILTER = 12
NLM_F_REQUEST, NLM_F_CREATE, NLM_F_EXCL, NLM_F_ACK = 1, 0x400, 0x200, 4
NFNL_SUBSYS_CTNETLINK, IPCTNL_MSG_CT_NEW = 1, 0
AF_INET, IPPROTO_TCP = 2, 6
IPS_CONFIRMED, IPS_SEEN_REPLY = 0x08, 0x02
CTA_TUPLE_ORIG, CTA_TUPLE_REPLY, CTA_STATUS = 1, 2, 3
CTA_TIMEOUT, CTA_ZONE = 7, 18
CTA_TUPLE_IP, CTA_TUPLE_PROTO = 1, 2
CTA_IP_V4_SRC, CTA_IP_V4_DST = 1, 2
CTA_PROTO_NUM, CTA_PROTO_SRC_PORT, CTA_PROTO_DST_PORT = 1, 2, 3
NLA_F_NESTED = 0x8000

def nla(t, d):
    L = 4 + len(d); return struct.pack('HH', L, t) + d + b'\0'*((4-(L%4))%4)

def nla_nest(t, *c):
    return nla(t | NLA_F_NESTED, b''.join(c))

def build_entry(src, dst, sp, dp, zone, timeout):
    def tup(tag, s, d, sp2, dp2):
        return nla_nest(tag,
            nla_nest(CTA_TUPLE_IP,
                nla(CTA_IP_V4_SRC, socket.inet_aton(s)),
                nla(CTA_IP_V4_DST, socket.inet_aton(d))),
            nla_nest(CTA_TUPLE_PROTO,
                nla(CTA_PROTO_NUM, struct.pack('B', IPPROTO_TCP)),
                nla(CTA_PROTO_SRC_PORT, struct.pack('!H', sp2)),
                nla(CTA_PROTO_DST_PORT, struct.pack('!H', dp2))))
    nfgen = struct.pack('BBH', AF_INET, 0, 0)
    return nfgen + tup(CTA_TUPLE_ORIG, src, dst, sp, dp) + \
           tup(CTA_TUPLE_REPLY, dst, src, dp, sp) + \
           nla(CTA_STATUS, struct.pack('!I', IPS_CONFIRMED|IPS_SEEN_REPLY)) + \
           nla(CTA_TIMEOUT, struct.pack('!I', timeout)) + \
           nla(CTA_ZONE, struct.pack('!H', zone))

def main():
    zone  = int(sys.argv[1]) if len(sys.argv) > 1 else 1001
    count = int(sys.argv[2]) if len(sys.argv) > 2 else 1000
    tmout = int(sys.argv[3]) if len(sys.argv) > 3 else 7200
    sock = socket.socket(socket.AF_NETLINK, socket.SOCK_RAW, NETLINK_NETFILTER)
    sock.bind((os.getpid(), 0))
    sock.settimeout(2.0)
    ok = err = 0
    mtype = (NFNL_SUBSYS_CTNETLINK << 8) | IPCTNL_MSG_CT_NEW
    flags = NLM_F_REQUEST | NLM_F_CREATE | NLM_F_EXCL | NLM_F_ACK
    for i in range(count):
        src = "10.%d.%d.%d" % ((i>>16)&0xFF, (i>>8)&0xFF, (i&0xFF)|1)
        payload = build_entry(src, "172.30.0.1", 10000+(i%55000), 443, zone, tmout)
        nlh = struct.pack('IHHII', 16+len(payload), mtype, flags, i+1, os.getpid())
        sock.sendto(nlh + payload, (0, 0))
        try:
            d = sock.recv(65536)
            if len(d) >= 20 and struct.unpack('i', d[16:20])[0] == 0: ok += 1
            else: err += 1
        except: err += 1
        if (i+1) % 10000 == 0:
            print(f"  {i+1}/{count} ok={ok} err={err}", flush=True)
    sock.close()
    print(f"Done: zone={zone} ok={ok} err={err}")

if __name__ == '__main__':
    main()
PYEOF

# Copy script to worker node and run injection
oc cp /tmp/ct_inject.py \
  "openshift-ovn-kubernetes/${OVN_POD}:/host/tmp/ct_inject.py" \
  -c ovnkube-controller 2>/dev/null

CT_BEFORE=$(oc exec -n openshift-ovn-kubernetes "$OVN_POD" -- \
  nsenter -t 1 -m -u -i -n -p -- \
  cat /proc/sys/net/netfilter/nf_conntrack_count 2>/dev/null)
echo "Before injection: $CT_BEFORE CT entries"

for zone in 1001 1002 1003 1004; do
  oc exec -n openshift-ovn-kubernetes "$OVN_POD" -c ovnkube-controller -- \
    nsenter -t 1 -m -u -i -n -p -- \
    bash -c "nohup python3 /tmp/ct_inject.py $zone ${CT_ENTRIES_PER_ZONE} ${CT_TIMEOUT_SECS} \
      > /tmp/ct${zone}.log 2>&1 &" 2>/dev/null
done
echo "Injection started in background (4 zones × ${CT_ENTRIES_PER_ZONE} entries)"

# Wait for CT to reach target (4 zones × CT_ENTRIES_PER_ZONE)
CT_TARGET=$((CT_ENTRIES_PER_ZONE * 4))
for i in $(seq 1 8); do
  sleep 15
  CT=$(oc exec -n openshift-ovn-kubernetes "$OVN_POD" -- \
    nsenter -t 1 -m -u -i -n -p -- \
    cat /proc/sys/net/netfilter/nf_conntrack_count 2>/dev/null)
  echo "  t+$((i*15))s: ${CT:-0} CT entries (target $CT_TARGET)"
  [ "${CT:-0}" -ge "$CT_TARGET" ] && echo "CT target reached" && break
done

if [ "${CT:-0}" -lt "$((CT_TARGET * 70 / 100))" ]; then
  echo "ERROR: Only ${CT:-0} CT entries injected, expected $CT_TARGET — aborting"
  exit 1
fi

# Verify each injector completed successfully
INJECT_FAIL=0
for zone in 1001 1002 1003 1004; do
  result=$(oc exec -n openshift-ovn-kubernetes "$OVN_POD" -c ovnkube-controller -- \
    nsenter -t 1 -m -u -i -n -p -- \
    cat /tmp/ct${zone}.log 2>/dev/null | tail -1 || echo "")
  ok=$(echo "$result" | grep -oP 'ok=\K[0-9]+' || echo 0)
  err=$(echo "$result" | grep -oP 'err=\K[0-9]+' || echo 0)
  echo "  Zone $zone: ok=$ok err=$err"
  if [ "${ok:-0}" -lt "$((CT_ENTRIES_PER_ZONE * 80 / 100))" ] || [ "${err:-0}" -gt "$((CT_ENTRIES_PER_ZONE * 10 / 100))" ]; then
    echo "  WARN: Zone $zone injection below threshold"
    INJECT_FAIL=1
  fi
done
if [ "$INJECT_FAIL" -ne 0 ]; then
  echo "ERROR: One or more CT injectors did not complete successfully — aborting"
  exit 1
fi

CT_AFTER=$(oc exec -n openshift-ovn-kubernetes "$OVN_POD" -- \
  nsenter -t 1 -m -u -i -n -p -- \
  cat /proc/sys/net/netfilter/nf_conntrack_count 2>/dev/null)
echo "CT entries after injection: $CT_AFTER"
echo "CT_before=$CT_BEFORE CT_after=$CT_AFTER" >> "$OUTDIR/info.txt"

# ── Step 4: Start monitoring captures ────────────────────────────────────────
echo ""
echo "=== Step 4: Starting captures ==="

# Start ovn-controller log capture
oc logs -n openshift-ovn-kubernetes -c ovn-controller "$OVN_POD" -f \
  2>/dev/null | grep --line-buffered -E \
  "Claiming lport|Setting lport.*ovn-installed|Unreasonably long|NXT_CT_FLUSH" \
  > "$OUTDIR/ovn-binding.txt" &
LOG_PID=$!

# ── Step 5: Create burst namespace + BURST_POD_COUNT pods ───────────────────
echo ""
echo "=== Step 5: Deploying ${BURST_POD_COUNT} burst pods ==="
oc create ns burst-test --dry-run=client -o yaml | oc apply -f - 2>/dev/null

oc apply -n burst-test -f - << BEOF 2>/dev/null
apiVersion: apps/v1
kind: Deployment
metadata:
  name: airflow-burst
spec:
  replicas: ${BURST_POD_COUNT}
  selector:
    matchLabels:
      app: airflow-burst
  template:
    metadata:
      labels:
        app: airflow-burst
    spec:
      nodeSelector:
        kubernetes.io/hostname: ${TARGET_NODE}
      containers:
      - name: c
        image: gcr.io/google_containers/pause:3.1
        resources:
          requests:
            cpu: 1m
            memory: 4Mi
BEOF

echo "Waiting for pods to be Running..."
for i in $(seq 1 12); do
  sleep 30
  RUNNING=$(oc get pods -n burst-test --no-headers 2>/dev/null | awk '/Running/{c++}END{print c+0}')
  echo "  t+$((i*30))s: $RUNNING pods Running"
  [ "$RUNNING" -ge "$((BURST_POD_COUNT * 80 / 100))" ] && break
done

if [ "$RUNNING" -lt "$((BURST_POD_COUNT * 80 / 100))" ]; then
  echo "ERROR: Only $RUNNING of $BURST_POD_COUNT burst pods became Running — aborting"
  exit 1
fi

# ── Step 6: Simultaneous burst deletion ──────────────────────────────────────
echo ""
echo "=== Step 6: BURST DELETION at $(date -u) ==="
CT_BURST=$(oc exec -n openshift-ovn-kubernetes "$OVN_POD" -- \
  nsenter -t 1 -m -u -i -n -p -- \
  cat /proc/sys/net/netfilter/nf_conntrack_count 2>/dev/null)
echo "CT during burst: $CT_BURST"
echo "CT_burst=$CT_BURST" >> "$OUTDIR/info.txt"

STALLS_BEFORE=$(oc exec -n openshift-ovn-kubernetes "$OVN_POD" -- \
  nsenter -t 1 -m -u -i -n -p -- \
  grep -c "Unreasonably long" /var/log/openvswitch/ovs-vswitchd.log 2>/dev/null || echo 0)
echo "OVS stall baseline: $STALLS_BEFORE"

TIMEOUTS_BEFORE=$(oc get events -n burst-test 2>/dev/null | \
  awk '/timed out waiting for OVS/{c++}END{print c+0}')
echo "CNI timeout baseline: $TIMEOUTS_BEFORE"

oc delete pods -n burst-test --all --grace-period=0 2>/dev/null
echo "${BURST_POD_COUNT} pods deleted simultaneously!"

# ── Step 7: Monitor for stalls and timeouts ──────────────────────────────────
echo ""
echo "=== Step 7: Monitoring (10 minutes) ==="
FINAL_TIMEOUTS=0
FINAL_STALLS=0

for i in $(seq 1 20); do
  sleep 30
  TIMEOUTS_RAW=$(oc get events -n burst-test 2>/dev/null | \
    awk '/timed out waiting for OVS/{c++}END{print c+0}')
  TIMEOUTS=$(( ${TIMEOUTS_RAW:-0} - ${TIMEOUTS_BEFORE:-0} ))
  STALLS_RAW=$(oc exec -n openshift-ovn-kubernetes "$OVN_POD" -- \
    nsenter -t 1 -m -u -i -n -p -- \
    grep -c "Unreasonably long" /var/log/openvswitch/ovs-vswitchd.log 2>/dev/null || echo 0)
  STALLS=$(( ${STALLS_RAW:-0} - ${STALLS_BEFORE:-0} ))
  echo "$(date -u +%H:%M:%S) timeouts=$TIMEOUTS stalls=$STALLS"
  FINAL_TIMEOUTS=$TIMEOUTS
  FINAL_STALLS=$STALLS
done

# ── Step 8: Collect evidence ─────────────────────────────────────────────────
echo ""
echo "=== Step 8: Collecting evidence ==="
kill $LOG_PID 2>/dev/null || true
kill $KB_PID 2>/dev/null || true

# Disable vconn debug
oc exec -n openshift-ovn-kubernetes "$OVN_POD" -- \
  nsenter -t 1 -m -u -i -n -p -- \
  ovs-appctl vlog/set vconn:file:info 2>/dev/null

# Collect OVS key events
oc exec -n openshift-ovn-kubernetes "$OVN_POD" -- \
  nsenter -t 1 -m -u -i -n -p -- \
  grep -E "Unreasonably long|NXT_CT_FLUSH|urcu.*quiesce" \
  /var/log/openvswitch/ovs-vswitchd.log 2>/dev/null \
  > "$OUTDIR/ovs-key-events.txt"

# Worst stalls
echo ""
echo "=== Worst OVS stalls ==="
grep "Unreasonably long" "$OUTDIR/ovs-key-events.txt" 2>/dev/null | \
  awk '{match($0,/([0-9]+)ms poll/,a); print a[1]+0, $0}' | \
  sort -rn | head -5 | awk '{$1=""; print}' | tee "$OUTDIR/worst-stalls.txt"

# CNI timeout samples
oc get events -n burst-test 2>/dev/null | \
  grep "timed out waiting for OVS" | head -3 > "$OUTDIR/cni-timeouts.txt"

# Summary
{
  echo "OCP=$OCP_VER"
  echo "target=$TARGET_NODE"
  echo "CT_entries=$CT_AFTER"
  echo "OVS_stalls=$FINAL_STALLS"
  echo "CNI_timeouts=$FINAL_TIMEOUTS"
  echo "burst_pods=$BURST_POD_COUNT"
} >> "$OUTDIR/info.txt"

echo ""
echo "================================================================"
echo " RESULTS"
echo "================================================================"
echo "OCP: $OCP_VER"
echo "CT entries: $CT_AFTER"
echo "OVS stalls (Unreasonably long): $FINAL_STALLS"
echo "CNI timeouts: $FINAL_TIMEOUTS"

# ── Validation ───────────────────────────────────────────────────────────────
echo ""
FAIL=0

if [ "$FINAL_STALLS" -lt "$EXPECTED_STALLS" ]; then
  echo "FAIL: Expected >= $EXPECTED_STALLS stalls, got $FINAL_STALLS"
  FAIL=1
else
  echo "PASS: OVS stalls ($FINAL_STALLS >= $EXPECTED_STALLS) ✅"
fi

if [ "$EXPECTED_TIMEOUTS" -gt 0 ] && [ "$FINAL_TIMEOUTS" -lt "$EXPECTED_TIMEOUTS" ]; then
  echo "FAIL: Expected >= $EXPECTED_TIMEOUTS CNI timeouts, got $FINAL_TIMEOUTS"
  FAIL=1
elif [ "$EXPECTED_TIMEOUTS" -gt 0 ]; then
  echo "PASS: CNI timeouts ($FINAL_TIMEOUTS >= $EXPECTED_TIMEOUTS) ✅"
fi

echo ""
if [ "$FAIL" -eq 0 ]; then
  echo "================================================================"
  echo " ✅ OCPBUGS-76596 REPRODUCED SUCCESSFULLY"
  echo " NXT_CT_FLUSH_ZONE + $CT_AFTER CT entries = $FINAL_STALLS stalls"
  echo "================================================================"
else
  echo "================================================================"
  echo " ❌ REPRODUCTION FAILED — check $OUTDIR/"
  echo "================================================================"
  exit 1
fi
