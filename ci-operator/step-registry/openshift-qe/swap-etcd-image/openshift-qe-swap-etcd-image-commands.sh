#!/bin/bash
# swap-etcd-image — replace the etcd operand image on a cluster by
# patching the etcd-operator's IMAGE env var.
set -o errexit
set -o pipefail

OP_NS=openshift-etcd-operator
ETCD_NS=openshift-etcd
CVO_NS=openshift-cluster-version
TIMEOUT="${ETCD_SWAP_TIMEOUT:-900}"

[ -n "${ETCD_IMAGE:-}" ] || { echo "FATAL: ETCD_IMAGE env var is required" >&2; exit 1; }

echo "=== Swapping etcd operand image to ${ETCD_IMAGE} ==="

# preflight
oc whoami > /dev/null || { echo "FATAL: not logged in" >&2; exit 1; }
n_masters=$(oc get nodes -l node-role.kubernetes.io/master= --no-headers | wc -l)
[ "${n_masters}" -ge 1 ] || { echo "FATAL: no master nodes found" >&2; exit 1; }
echo "cluster:     $(oc whoami --show-server)"
echo "masters:     ${n_masters}"

# safety: target must not be the operator's own container image
op_image=$(oc -n "${OP_NS}" get deploy etcd-operator -o jsonpath='{.spec.template.spec.containers[0].image}')
if [ "${ETCD_IMAGE}" = "${op_image}" ]; then
  echo "FATAL: target image equals the etcd-operator's own image (${op_image})" >&2
  echo "       that is the OPERATOR image, not the etcd operand — aborting" >&2
  exit 1
fi
echo "operator's own image (never changed): ${op_image}"
echo "target etcd operand: ${ETCD_IMAGE}"

current=$(oc -n "${OP_NS}" get deploy etcd-operator -o \
  jsonpath='{.spec.template.spec.containers[0].env[?(@.name=="IMAGE")].value}')
if [ "${current}" = "${ETCD_IMAGE}" ]; then
  echo "operator IMAGE env already set to the target — nothing to do"
  exit 0
fi
echo "current etcd: ${current}"

# CVO guard: scale to 0 so it cannot revert the operator patch
replicas=$(oc -n "${CVO_NS}" get deploy cluster-version-operator -o jsonpath='{.spec.replicas}')
if [ "${replicas}" != "0" ]; then
  echo "scaling CVO to 0 so it cannot revert the operator patch"
  oc -n "${CVO_NS}" scale deploy cluster-version-operator --replicas=0
fi

# ensure etcd-operator is running
op_replicas=$(oc -n "${OP_NS}" get deploy etcd-operator -o jsonpath='{.spec.replicas}')
if [ "${op_replicas}" = "0" ]; then
  echo "etcd-operator at 0 replicas, scaling to 1"
  oc -n "${OP_NS}" scale deploy etcd-operator --replicas=1
fi

# patch
echo "setting operator IMAGE env and waiting for the roll..."
oc -n "${OP_NS}" set env deploy/etcd-operator "IMAGE=${ETCD_IMAGE}"

# wait for roll
deadline=$(( $(date +%s) + TIMEOUT ))
last=""
completed=0
OPERAND_IMG='{.spec.containers[?(@.name=="etcd")].image}'
while [ "$(date +%s)" -lt "${deadline}" ]; do
  n_target=$(oc -n "${ETCD_NS}" get pods -l app=etcd \
    -o jsonpath="{range .items[*]}${OPERAND_IMG}{\"\\n\"}{end}" \
    2>/dev/null | grep -cxF "${ETCD_IMAGE}" || true)
  running=$(oc -n "${ETCD_NS}" get pods -l app=etcd --no-headers 2>/dev/null | \
    awk '{split($2,r,"/"); if (r[1]==r[2] && $3=="Running") c++} END {print c+0}')
  status="etcd on target: ${n_target}/${n_masters}, ready: ${running}/${n_masters}"
  [ "${status}" != "${last}" ] && echo "  ${status}"
  last="${status}"
  if [ "${n_target}" -eq "${n_masters}" ] && [ "${running}" -eq "${n_masters}" ]; then
    completed=1
    echo "roll complete: all ${n_masters} etcd members run ${ETCD_IMAGE} in container \"etcd\""
    break
  fi
  sleep 20
done
if [ "${completed}" -ne 1 ]; then
  echo "WARNING: timed out after ${TIMEOUT}s — roll incomplete:" >&2
  oc -n "${ETCD_NS}" get pods -l app=etcd -o custom-columns='NAME:.metadata.name,STATUS:.status.phase,ETCD_IMAGE:.spec.containers[?(@.name=="etcd")].image' --no-headers >&2
  exit 1
fi

# version display
echo "etcd version (per member):"
for pod in $(oc -n "${ETCD_NS}" get pods -l app=etcd -o name | sed 's|^pod/||'); do
  echo "--- ${pod}"
  oc -n "${ETCD_NS}" exec "${pod}" -c etcd -- etcd --version 2>/dev/null | sed 's/^/  /' || echo "  (exec failed)"
done

# health
sleep 15
oc wait --for=condition=Available=True clusteroperator/etcd --timeout=180s \
  && echo "clusteroperator/etcd Available" \
  || echo "WARNING: clusteroperator/etcd not Available yet — check 'oc get co etcd'"

echo "done. etcd members (container \"etcd\"):"
oc -n "${ETCD_NS}" get pods -l app=etcd -o custom-columns='NAME:.metadata.name,STATUS:.status.phase,ETCD_IMAGE:.spec.containers[?(@.name=="etcd")].image' --no-headers
echo "etcd-operator (unchanged): ${op_image}"
