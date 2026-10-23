#!/bin/bash
# apply-etcd-readahead-mc.sh — prow step: cap the bdi readahead window on the
# etcd volume of every master, via MachineConfig, and wait for the master
# MachineConfigPool to roll.
#
# Why: OCP 5.0 etcd dropped madvise(MADV_RANDOM) (bbolt#939 / PR #395). With
# RHCOS stock read_ahead_kb=4096 (tuned virtual-guest) and the kubepods
# cgroup pinned, every etcd page fault drags in a 4 MiB window and evicts
# pages still in use -> read-back storms and latency spikes. Capping the
# readahead removes the amplifier (validated by the standalone rakill cell:
# 124.6 -> 3.5 MiB/s read-back, ~2100x -> 1.0x amplification).
#
# What it does:
#   1. waits for the master MCP to be steady (Updated)
#   2. creates/replaces MC <mc-name> that installs a oneshot unit which
#      resolves the bdi backing /var/lib/etcd at boot and writes the knob
#   3. waits for the master MCP to pick up the new rendered config (start
#      of the update), then to finish (Updated)
#   4. verifies the knob value live on every master
#
# Usage:
#   ./apply-etcd-readahead-mc.sh [options]
#   ./apply-etcd-readahead-mc.sh --delete   (remove the MC and wait the roll)
#
# Options / environment:
#   --readahead-kb N   target value in KiB (default: 128; kernel default.
#                      Bounds amplification at 32 pages while keeping
#                      compaction bulk prefetch. Use 4 to replicate the
#                      standalone rakill cell exactly.)
#   --mc-name NAME     MachineConfig name (default: 99-etcd-bdi-readahead)
#   --timeout SECS     timeout for the pool to finish updating
#                      (default: 3600 — master rolls drain one at a time)
#   --delete           remove the MC instead of applying it, wait for roll
#
# Requires: oc with an admin KUBECONFIG (prow steps have it in the env).
# Exits non-zero on any failure so the prow step fails cleanly.

set -o errexit
set -o pipefail

READAHEAD_KB="${READAHEAD_KB:-128}"
MC_NAME="99-etcd-bdi-readahead"
TIMEOUT=3600
MODE=apply

while [[ $# -gt 0 ]]; do
  case "$1" in
    --readahead-kb) READAHEAD_KB="$2"; shift 2 ;;
    --mc-name)      MC_NAME="$2"; shift 2 ;;
    --timeout)      TIMEOUT="$2"; shift 2 ;;
    --delete)       MODE=delete; shift ;;
    -h|--help)      grep '^#' "$0" | tail -n +2 | sed 's/^# \{0,1\}//'; exit 0 ;;
    *) echo "unknown option: $1" >&2; exit 2 ;;
  esac
done

case "${READAHEAD_KB}" in
  ''|*[!0-9]*) echo "FATAL: --readahead-kb must be an integer (got '${READAHEAD_KB}')" >&2; exit 1 ;;
esac
[ "${READAHEAD_KB}" -ge 4 ] || { echo "FATAL: --readahead-kb must be >= 4 (one page)" >&2; exit 1; }

MCP=master
ts()  { date -u +%H:%M:%S; }
fail(){ echo "FATAL: $*" >&2; exit 1; }

# ---------------------------------------------------------------- preflight
echo "[$(ts)] preflight"
oc whoami > /dev/null 2>&1 || fail "oc not usable (check KUBECONFIG)"
echo "  api server: $(oc whoami --show-server)"
oc get mcp "${MCP}" > /dev/null 2>&1 || fail "mcp/${MCP} not found"
echo "  cluster:    $(oc get clusterversion -o jsonpath='{.items[0].status.desired.version}' 2>/dev/null || echo unknown)"

# Start from a steady pool: if something else is mid-update, wait it out.
oc wait "mcp/${MCP}" --for=condition=Updated --timeout=900s \
  || fail "mcp/${MCP} not Updated before start (another update in flight?)"

RENDERED_BEFORE=$(oc get "mcp/${MCP}" -o jsonpath='{.status.configuration.name}')
echo "  rendered:   ${RENDERED_BEFORE}"

# ---------------------------------------------------------------- build MC
MC_FILE=$(mktemp --suffix=.mc.yaml)
trap 'rm -f "${MC_FILE}"' EXIT

# Node-side oneshot: resolve the bdi backing /var/lib/etcd and cap its
# readahead window. Gotchas baked in from the 2026-10-27 run on RHCOS:
#   - /var/lib/etcd is usually a PARTITION (e.g. nvme0n1p4, 259:4) and
#     partitions have no bdi entry of their own (/sys/class/bdi/259:4 does
#     not exist) — resolve to the whole disk via lsblk PKNAME (259:0).
#   - dm/LVM stacks DO have their own bdi (used directly).
#   - lsblk pads columns: trim whitespace from everything it prints.
#   - knob name differs by kernel (RHEL: read_ahead_kb, mainline:
#     readahead_kb) — detect by scanning the bdi directory, not [ -e ].
NODE_SCRIPT=$(cat <<'EOS'
#!/bin/bash
set -euo pipefail
TARGET=__VALUE__
log() { echo "etcd-bdi-readahead: $*"; }
trim() { tr -d '[:space:]'; }

src=$(findmnt -no SOURCE -T /var/lib/etcd 2>/dev/null) || src=""
[ -n "${src}" ] || src=$(findmnt -no SOURCE -T /)
case "${src}" in /dev/*) ;; *) src="/dev/${src}" ;; esac
src="${src%%\[*}"
mm=$(lsblk -no MAJ:MIN "${src}" 2>/dev/null | head -1 | trim)
[ -n "${mm}" ] || { log "FATAL: cannot resolve device for ${src}"; exit 1; }

# partitions share the whole disk's bdi; dm devices have their own
if [ -e "/sys/class/bdi/${mm}" ]; then
  bdi="${mm}"
else
  parent=$(lsblk -no PKNAME "${src}" 2>/dev/null | head -1 | trim)
  if [ -n "${parent}" ] && [ -e "/sys/block/${parent}" ]; then
    bdi=$(cat "/sys/block/${parent}/dev" 2>/dev/null | trim)
  else
    bdi="${mm}"
  fi
fi
[ -n "${bdi}" ] || { log "FATAL: cannot resolve bdi for ${src} (${mm})"; exit 1; }

knob=$(ls "/sys/class/bdi/${bdi}" 2>/dev/null | grep -xE 'read_ahead_kb|readahead_kb' | head -1)
[ -n "${knob}" ] || { log "FATAL: no readahead knob under /sys/class/bdi/${bdi}"; exit 1; }

cur=$(cat "/sys/class/bdi/${bdi}/${knob}")
[ "${cur}" = "${TARGET}" ] || echo "${TARGET}" > "/sys/class/bdi/${bdi}/${knob}"
now=$(cat "/sys/class/bdi/${bdi}/${knob}")
log "${src} (${mm}) bdi=${bdi} ${knob}: ${cur} -> ${now} KiB"
[ "${now}" = "${TARGET}" ] || { log "FATAL: value is ${now}, expected ${TARGET}"; exit 1; }
EOS
)
NODE_SCRIPT="${NODE_SCRIPT//__VALUE__/${READAHEAD_KB}}"
B64=$(printf '%s' "${NODE_SCRIPT}" | base64 -w 0)

cat > "${MC_FILE}" <<EOF
apiVersion: machineconfiguration.openshift.io/v1
kind: MachineConfig
metadata:
  labels:
    machineconfiguration.openshift.io/role: ${MCP}
  name: ${MC_NAME}
spec:
  config:
    ignition:
      version: 3.2.0
    storage:
      files:
      - path: /usr/local/sbin/etcd-bdi-readahead
        mode: 493
        overwrite: true
        contents:
          source: data:text/plain;charset=utf-8;base64,${B64}
    systemd:
      units:
      - name: etcd-bdi-readahead.service
        enabled: true
        contents: |
          [Unit]
          Description=Cap bdi readahead on the etcd volume (OCP 5.0 read-back validation)
          After=local-fs.target
          ConditionPathExists=/var/lib/etcd
          [Service]
          Type=oneshot
          ExecStart=/usr/local/sbin/etcd-bdi-readahead
          RemainAfterExit=yes
          [Install]
          WantedBy=multi-user.target
EOF

# ---------------------------------------------------------------- apply/delete
if [ "${MODE}" = "delete" ]; then
  echo "[$(ts)] deleting MC ${MC_NAME}"
  oc get "mc/${MC_NAME}" > /dev/null 2>&1 || { echo "MC ${MC_NAME} not found; nothing to do"; exit 0; }
  oc delete "mc/${MC_NAME}"
else
  echo "[$(ts)] applying MC ${MC_NAME} (read_ahead_kb=${READAHEAD_KB} on masters' etcd-volume bdi)"
  oc apply -f "${MC_FILE}"
fi

# ---------------------------------------------------------------- wait: start
# The update "starts" when the MCO renders a new config for the pool. Watching
# the rendered name also disambiguates a no-op rerun (identical MC content ->
# no new render -> no roll), which must not hang the step.
echo "[$(ts)] waiting for mcp/${MCP} to start updating (new rendered config)"
started=""
deadline=$(( $(date +%s) + 300 ))
while [ "$(date +%s)" -lt "${deadline}" ]; do
  rendered=$(oc get "mcp/${MCP}" -o jsonpath='{.status.configuration.name}')
  if [ "${rendered}" != "${RENDERED_BEFORE}" ]; then started=1; break; fi
  sleep 5
done
if [ -z "${started}" ]; then
  if oc get "mcp/${MCP}" -o jsonpath='{.status.configuration.source}' | tr ' ' '\n' | grep -q "${MC_NAME}"; then
    echo "[$(ts)] MC already rendered with identical content (rerun); no roll needed"
  else
    fail "mcp/${MCP} did not pick up a new rendered config within 300s"
  fi
else
  echo "[$(ts)] update started: ${RENDERED_BEFORE} -> ${rendered}"
  # Updating should flip within seconds of the new render; the roll itself
  # keeps it True for the duration (masters drain one at a time).
  if ! oc wait "mcp/${MCP}" --for=condition=Updating --timeout=600s; then
    updated=$(oc get "mcp/${MCP}" -o jsonpath='{.status.conditions[?(@.type=="Updated")].status}')
    if [ "${updated}" = "True" ]; then
      echo "[$(ts)] WARNING: missed the Updating window; pool already Updated"
    else
      fail "mcp/${MCP} never entered Updating"
    fi
  fi
fi

# ---------------------------------------------------------------- wait: done
echo "[$(ts)] waiting for mcp/${MCP} to finish updating (timeout ${TIMEOUT}s)"
oc wait "mcp/${MCP}" --for=condition=Updated --timeout="${TIMEOUT}s" \
  || fail "mcp/${MCP} did not finish updating within ${TIMEOUT}s"
echo "[$(ts)] mcp/${MCP} Updated: $(oc get "mcp/${MCP}" -o jsonpath='{.status.configuration.name}')"

DEGRADED=$(oc get "mcp/${MCP}" -o jsonpath='{.status.conditions[?(@.type=="Degraded")].status}')
[ "${DEGRADED}" = "True" ] && fail "mcp/${MCP} is Degraded after the roll"
[ "${MODE}" = "delete" ] && { echo "[$(ts)] done (MC removed)"; exit 0; }

# ---------------------------------------------------------------- verify
# The roll rebooted every master; the oneshot ran at boot. Prove the knob on
# each node live (nsenter into the host mount namespace: /sys must be the
# host's sysfs).
echo "[$(ts)] verifying knob on every master"
RC=0
for node in $(oc get nodes -l node-role.kubernetes.io/master= -o jsonpath='{range .items[*]}{.metadata.name}{"\n"}{end}'); do
  out=$(oc debug "node/${node}" -- nsenter -t 1 -m -- bash -c '
    trim() { tr -d "[:space:]"; }
    src=$(findmnt -no SOURCE -T /var/lib/etcd 2>/dev/null) || src=""
    [ -n "${src}" ] || src=$(findmnt -no SOURCE -T /)
    case "${src}" in /dev/*) ;; *) src="/dev/${src}" ;; esac
    src="${src%%\[*}"
    mm=$(lsblk -no MAJ:MIN "${src}" 2>/dev/null | head -1 | trim)
    if [ -e "/sys/class/bdi/${mm}" ]; then bdi="${mm}"
    else
      parent=$(lsblk -no PKNAME "${src}" 2>/dev/null | head -1 | trim)
      [ -n "${parent}" ] && [ -e "/sys/block/${parent}" ] \
        && bdi=$(cat "/sys/block/${parent}/dev" 2>/dev/null | trim) || bdi="${mm}"
    fi
    knob=$(ls "/sys/class/bdi/${bdi}" 2>/dev/null | grep -xE "read_ahead_kb|readahead_kb" | head -1)
    unit=$(systemctl is-active etcd-bdi-readahead.service 2>/dev/null || echo unknown)
    echo "${bdi} ${knob} $(cat "/sys/class/bdi/${bdi}/${knob}" 2>/dev/null || echo "?") unit=${unit}"
  ' 2>/dev/null | grep -E '^[0-9]+:[0-9]+ (read_ahead_kb|readahead_kb) [0-9]+ unit=' | tail -1)
  val=$(echo "${out}" | awk '{print $3}')
  if [ "${val}" = "${READAHEAD_KB}" ]; then
    echo "  ${node}: ${out}  OK"
  else
    echo "  ${node}: got '${out:-<no output>}', expected read_ahead_kb=${READAHEAD_KB}" >&2
    RC=1
  fi
done
[ "${RC}" -eq 0 ] || fail "knob verification failed on one or more masters"

echo "[$(ts)] done: readahead capped at ${READAHEAD_KB} KiB on all masters (MC ${MC_NAME})"
