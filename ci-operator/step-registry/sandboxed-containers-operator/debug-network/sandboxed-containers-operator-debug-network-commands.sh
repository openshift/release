#!/bin/bash
#
# TEMPORARY debug step for investigating the C00316 (cosigned pod / skr-openshift)
# "context deadline exceeded" timeout on azure-ipi-coco-disconnected.
#
# Purely read-only / diagnostic. Every command is best-effort and wrapped so
# that nothing here can fail or hang the job: this step must never affect the
# pass/fail result of the pipeline, and must never block for long.
#
# Runs right after openshift-extended-test (first item in `post`), while the
# cluster is still fully alive, and writes everything to $ARTIFACT_DIR so it
# lands in the normal (public, for rehearsals) job artifacts - no cluster
# access or credentials needed to read the results afterwards.

set +e
set +o pipefail

OUT="${ARTIFACT_DIR:-/tmp}/debug-network"
mkdir -p "${OUT}"

run() {
  local label="$1"; shift
  echo "=== ${label} ===" | tee -a "${OUT}/summary.txt"
  timeout 60 "$@" >>"${OUT}/summary.txt" 2>&1
  echo "(exit: $?)" >> "${OUT}/summary.txt"
  echo >> "${OUT}/summary.txt"
}

echo "Debug-network step starting at $(date -u)" | tee "${OUT}/summary.txt"

# 1. Trustee route host, as seen by a normal (non-guest) client in-cluster.
TRUSTEE_HOST=""
if oc get route -n trustee-operator-system &>/dev/null; then
  TRUSTEE_HOST=$(oc get route -n trustee-operator-system -o jsonpath='{.items[0].spec.host}' 2>/dev/null || true)
fi
echo "TRUSTEE_HOST=${TRUSTEE_HOST}" | tee -a "${OUT}/summary.txt"

WORKER=$(oc get nodes -l node-role.kubernetes.io/worker --no-headers -o custom-columns=':metadata.name' 2>/dev/null | head -1)
echo "WORKER=${WORKER}" | tee -a "${OUT}/summary.txt"

if [[ -n "${WORKER}" && -n "${TRUSTEE_HOST}" ]]; then
  # 2. DNS resolution of the KBS/apps route from a worker node (public vs private IP).
  run "DNS resolution of ${TRUSTEE_HOST} from worker" \
    oc debug node/"${WORKER}" -- chroot /host getent hosts "${TRUSTEE_HOST}"

  # 3. Connectivity + timing to the KBS route from a worker node.
  run "curl timing to https://${TRUSTEE_HOST}/ from worker" \
    oc debug node/"${WORKER}" -- chroot /host curl -k -sS -o /dev/null \
      -w 'http_code=%{http_code} time_namelookup=%{time_namelookup} time_connect=%{time_connect} time_total=%{time_total}\n' \
      --max-time 15 "https://${TRUSTEE_HOST}/"
else
  echo "Skipping DNS/curl checks: missing WORKER or TRUSTEE_HOST" | tee -a "${OUT}/summary.txt"
fi

# 4. Pods in the OSC namespace, to spot podvm/CAA related resources.
run "pods in openshift-sandboxed-containers-operator" \
  oc get pods -n openshift-sandboxed-containers-operator -o wide

# 5. Logs from any pod whose name suggests it's the cloud-api-adaptor
#    (peer-pods VM lifecycle), best-effort, one file per pod.
CAA_PODS=$(oc get pods -n openshift-sandboxed-containers-operator --no-headers -o custom-columns=':metadata.name' 2>/dev/null | grep -i 'caa' || true)
if [[ -n "${CAA_PODS}" ]]; then
  while IFS= read -r pod; do
    [[ -z "${pod}" ]] && continue
    timeout 60 oc logs -n openshift-sandboxed-containers-operator "${pod}" --all-containers --tail=2000 \
      > "${OUT}/caa-log-${pod}.txt" 2>&1
  done <<< "${CAA_PODS}"
else
  echo "No CAA pod found" | tee -a "${OUT}/summary.txt"
fi

echo "Debug-network step finished at $(date -u)" | tee -a "${OUT}/summary.txt"

# Always succeed: this step must never affect job pass/fail.
exit 0
