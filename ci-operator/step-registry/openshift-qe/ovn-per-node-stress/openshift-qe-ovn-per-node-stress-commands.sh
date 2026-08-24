#!/bin/bash
set -o errexit
set -o nounset
set -o pipefail

if test -f "${SHARED_DIR}/proxy-conf.sh"; then
  # shellcheck disable=SC1090
  source "${SHARED_DIR}/proxy-conf.sh"
fi

set -x

PODS_PER_NODE="${PODS_PER_NODE:-400}"
MAX_PODS="${MAX_PODS:-2500}"
STRESS_NAMESPACE="${STRESS_NAMESPACE:-test-ocpbugs-98252}"
STRESS_IMAGE="${STRESS_IMAGE:-quay.io/centos/centos:stream9}"
STRESS_TIMEOUT="${STRESS_TIMEOUT:-45m}"
REPORT="${ARTIFACT_DIR}/ovn-per-node-stress.log"
FAILURES=0

log() {
    echo "$*" | tee -a "${REPORT}"
}

cleanup() {
    set +e
    oc scale deployment --all --replicas=0 -n "${STRESS_NAMESPACE}" --request-timeout=120s 2>/dev/null || true
    oc delete namespace "${STRESS_NAMESPACE}" --wait=false --request-timeout=120s 2>/dev/null || true
}
trap cleanup EXIT

mkdir -p "${ARTIFACT_DIR}"
: > "${REPORT}"

log "========================================"
log "OCPBUGS-98252 per-node stress: ${PODS_PER_NODE} pods pinned per worker"
log "Date: $(date '+%Y-%m-%d %H:%M:%S')"
log "Namespace: ${STRESS_NAMESPACE}"
log "Image: ${STRESS_IMAGE}"
log "========================================"
log ""

log "=== Waiting for worker maxPods=${MAX_PODS} ==="
for i in $(seq 1 80); do
    read -r -a caps <<< "$(oc get nodes -l node-role.kubernetes.io/worker= \
        -o jsonpath='{range .items[*]}{.status.capacity.pods}{" "}{end}')"
    if [[ ${#caps[@]} -gt 0 ]] && [[ "${caps[*]// /}" != "" ]]; then
        all_ready=true
        for cap in "${caps[@]}"; do
            if [[ "${cap}" -lt "${MAX_PODS}" ]]; then
                all_ready=false
                break
            fi
        done
        if ${all_ready}; then
            break
        fi
    fi
    oc wait mcp/worker --for=condition=Updated=True --timeout=5m 2>/dev/null || true
    sleep 15
done

mapfile -t WORKERS < <(oc get nodes -l node-role.kubernetes.io/worker= \
    -o jsonpath='{range .items[*]}{.metadata.name}{"\n"}{end}')

if [[ ${#WORKERS[@]} -eq 0 ]]; then
    log "ERROR: no worker nodes found"
    exit 1
fi

for worker in "${WORKERS[@]}"; do
    cap=$(oc get node "${worker}" -o jsonpath='{.status.capacity.pods}')
    if [[ "${cap}" -lt $((PODS_PER_NODE + 20)) ]]; then
        log "ERROR: ${worker} maxPods=${cap}, need at least $((PODS_PER_NODE + 20))"
        FAILURES=$((FAILURES + 1))
    fi
done
if [[ ${FAILURES} -gt 0 ]]; then
    exit 1
fi

oc create namespace "${STRESS_NAMESPACE}" --dry-run=client -o yaml | oc apply -f -

expand_node_subnet() {
    local node="$1"
    local current
    current=$(oc get node "${node}" -o jsonpath='{.metadata.annotations.k8s\.ovn\.org/node-subnets}' 2>/dev/null || true)
    if [[ -z "${current}" ]]; then
        log "WARN: ${node} has no k8s.ovn.org/node-subnets annotation; relying on install-time /21"
        return 0
    fi
    # Expand host prefix to /21 when the annotated subnet is narrower than /21.
    local cidr
    cidr=$(CURRENT="${current}" python3 <<'PY'
import json
import ipaddress
import os
import sys

raw = os.environ.get("CURRENT", "")
if not raw:
    sys.exit(0)
data = json.loads(raw)
cidr = data.get("default", [None])[0]
if not cidr:
    print(json.dumps(data))
    sys.exit(0)
net = ipaddress.ip_network(cidr, strict=False)
if net.prefixlen > 21:
    data["default"] = [str(net.supernet(new_prefix=21))]
print(json.dumps(data))
PY
)
    if [[ -n "${cidr}" && "${cidr}" != "${current}" ]]; then
        oc annotate node "${node}" "k8s.ovn.org/node-subnets=${cidr}" --overwrite
        log "Expanded subnet on ${node}: ${current} -> ${cidr}"
    else
        log "Subnet OK on ${node}: ${current}"
    fi
}

prepull_image() {
    local node="$1"
    log "Pre-pulling ${STRESS_IMAGE} on ${node}..."
    oc debug "node/${node}" -- chroot /host crictl pull "${STRESS_IMAGE}" >> "${REPORT}" 2>&1 || {
        log "WARN: pre-pull failed on ${node}; continuing anyway"
    }
}

deploy_on_node() {
    local node="$1"
    local dep_name="ocpbugs-98252-stress-${node%%.*}"
    dep_name="${dep_name//./-}"

    expand_node_subnet "${node}"
    prepull_image "${node}"

    log ""
    log "=== Deploying ${PODS_PER_NODE} pods on ${node} (deployment ${dep_name}) ==="
    local start_ts
    start_ts=$(date -Iseconds)

    cat <<EOF | oc apply -f -
apiVersion: apps/v1
kind: Deployment
metadata:
  name: ${dep_name}
  namespace: ${STRESS_NAMESPACE}
spec:
  replicas: ${PODS_PER_NODE}
  selector:
    matchLabels:
      app: ${dep_name}
  strategy:
    type: RollingUpdate
    rollingUpdate:
      maxSurge: 10%
      maxUnavailable: 0
  template:
    metadata:
      labels:
        app: ${dep_name}
    spec:
      nodeSelector:
        kubernetes.io/hostname: ${node}
      containers:
      - name: test-container
        image: ${STRESS_IMAGE}
        command: ["/bin/sh", "-c", "while true; do sleep 30; done"]
        resources:
          requests:
            cpu: 1m
            memory: 8Mi
          limits:
            cpu: 10m
            memory: 32Mi
EOF

    local end_ts running stuck cc
    if ! end_ts=$(oc wait "deployment/${dep_name}" -n "${STRESS_NAMESPACE}" \
        --for=condition=Available --timeout="${STRESS_TIMEOUT}" -o jsonpath='{.status.conditions[?(@.type=="Available")].lastUpdateTime}' 2>>"${REPORT}"); then
        running=$(oc get pods -n "${STRESS_NAMESPACE}" --field-selector "spec.nodeName=${node}" --no-headers 2>/dev/null | awk '$3=="Running"{c++} END{print c+0}')
        stuck=$(oc get pods -n "${STRESS_NAMESPACE}" --field-selector "spec.nodeName=${node}" --no-headers 2>/dev/null | awk '$3=="ContainerCreating"{c++} END{print c+0}')
        log "FAIL: ${node} did not reach ${PODS_PER_NODE} Available within ${STRESS_TIMEOUT} (Running=${running}, ContainerCreating=${stuck})"
        oc get pods -n "${STRESS_NAMESPACE}" --field-selector "spec.nodeName=${node}" --no-headers 2>/dev/null \
            | awk '{print $3}' | sort | uniq -c | sort -rn | tee -a "${REPORT}" || true
        FAILURES=$((FAILURES + 1))
        return 1
    fi

    running=$(oc get pods -n "${STRESS_NAMESPACE}" --field-selector "spec.nodeName=${node}" --no-headers 2>/dev/null | awk '$3=="Running"{c++} END{print c+0}')
    stuck=$(oc get pods -n "${STRESS_NAMESPACE}" --field-selector "spec.nodeName=${node}" --no-headers 2>/dev/null | awk '$3=="ContainerCreating"{c++} END{print c+0}')
    cc=$(oc get pods -n "${STRESS_NAMESPACE}" --field-selector "spec.nodeName=${node}" --no-headers 2>/dev/null | wc -l)
    ovs_count=$(oc debug "node/${node}" -- chroot /host pgrep -c ovs-vsctl 2>/dev/null || echo 0)

    log "PASS: ${node} Running=${running} total_on_node=${cc} ContainerCreating=${stuck} ovs-vsctl=${ovs_count}"
    log "  started: ${start_ts}  available: ${end_ts}"

    if [[ "${running}" -lt "${PODS_PER_NODE}" ]] || [[ "${stuck}" -gt 0 ]]; then
        log "FAIL: ${node} expected ${PODS_PER_NODE} Running with 0 ContainerCreating"
        FAILURES=$((FAILURES + 1))
        return 1
    fi
}

for worker in "${WORKERS[@]}"; do
    deploy_on_node "${worker}"
done

log ""
log "========================================"
log "Per-node stress summary"
log "  workers tested: ${#WORKERS[@]}"
log "  pods per worker: ${PODS_PER_NODE}"
log "  failures: ${FAILURES}"
log "========================================"

if [[ ${FAILURES} -gt 0 ]]; then
    exit 1
fi
