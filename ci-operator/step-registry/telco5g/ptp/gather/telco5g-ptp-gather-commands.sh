#!/bin/bash

set -o nounset
set -o errexit
set -o pipefail

# Keep a per-phase log in the job artifacts; ci-operator uploads it to Prow.
if [[ -n "${ARTIFACT_DIR:-}" ]]; then
  exec > >(tee -a "${ARTIFACT_DIR}/gather.log") 2>&1
fi

if [ -x "$HOME/fix_uid.sh" ]; then
  "$HOME/fix_uid.sh"
fi

# Emit a machine-readable step marker for log scrapers. The timestamp is UTC.
step_marker() {
  local timestamp was_tracing=false
  [[ $- == *x* ]] && was_tracing=true
  { set +x; } 2>/dev/null
  timestamp="$(date -u +%Y-%m-%dT%H:%M:%SZ)"
  printf '[STEP] %s - %s\n' "${timestamp}" "$*"
  if ${was_tracing}; then set -x; fi
}

step_marker "Configure hypervisor access"

# When this step runs on the hypervisor itself (local phase commands), run the
# same commands locally instead of over SSH.
if [[ "${HYPERVISOR_LOCAL:-false}" == "true" ]]; then
  hv_ssh() { bash -c "$*"; }
else
  CLUSTER_HV_IP="$(cat "$SHARED_DIR/hv-ip" 2>/dev/null || echo 10.6.34.246)"
  BASTION_IP="$(cat /var/run/bastion-ip/bastionip)"
  BASTION_USER="$(cat /var/run/bastion-user/bastionuser)"
  SSH_PKEY="${HOME}/key"
  cp /var/run/ci-key/cikey "$SSH_PKEY"
  chmod 600 "$SSH_PKEY"
  COMMON_SSH_ARGS="-o UserKnownHostsFile=/dev/null -o StrictHostKeyChecking=no -o ServerAliveInterval=30"
  hv_ssh() {
    ssh -i "${SSH_PKEY}" ${COMMON_SSH_ARGS} -C -o BatchMode=yes \
      -o "ProxyCommand=ssh -i ${SSH_PKEY} ${COMMON_SSH_ARGS} -o BatchMode=yes -W %h:%p -q ${BASTION_USER}@${BASTION_IP}" \
      "kni@${CLUSTER_HV_IP}" "$@"
  }
fi

# Session lock shared by the PTP phases. The owning pod refreshes a heartbeat
# while its phase runs; a lock whose container is gone or whose heartbeat
# stopped is reclaimed, so a cancelled job does not block the next one.
SESSION_LOCK="\$HOME/ptp-session.lock"
SESSION_HEARTBEAT="\$HOME/ptp-session.beat"
SESSION_STALE_SECONDS="${SESSION_STALE_SECONDS:-180}"
SESSION_WAIT_SECONDS="${SESSION_WAIT_SECONDS:-600}"
JOB_ID="${BUILD_ID:-${PROW_JOB_ID:-local-$(date +%s)-$$}}"
PHASE=gather
CONTAINER=telco5g-ptp-gather

session_field() {
  hv_ssh "sed -n 's/^$1=//p' ${SESSION_LOCK} 2>/dev/null" || true
}

session_lock_write() {
  hv_ssh "printf 'job=%s\nphase=%s\ncontainer=%s\nstarted=%s\n' '${JOB_ID}' '${PHASE}' '${CONTAINER}' '$(date +%s)' > ${SESSION_LOCK} && date +%s > ${SESSION_HEARTBEAT}"
}

session_lock_acquire() {
  local owner container phase beat age deadline
  deadline=$((SECONDS + SESSION_WAIT_SECONDS))
  while hv_ssh "test -f ${SESSION_LOCK}"; do
    owner="$(session_field job)"
    container="$(session_field container)"
    phase="$(session_field phase)"
    if [[ "${owner}" == "${JOB_ID}" ]]; then
      echo "INFO: session lock already owned by this job (${JOB_ID})"
      session_lock_write
      return 0
    fi
    if [[ -n "${container}" ]] && ! hv_ssh "podman container exists ${container} >/dev/null 2>&1"; then
      echo "INFO: reclaiming the session lock: phase '${phase}' container ${container} no longer exists"
    else
      beat="$(hv_ssh "cat ${SESSION_HEARTBEAT} 2>/dev/null" || true)"
      age=999999
      if [[ "${beat}" =~ ^[0-9]+$ ]]; then age=$(( $(date +%s) - beat )); fi
      if (( age > SESSION_STALE_SECONDS )); then
        echo "INFO: reclaiming the session lock: job ${owner} phase '${phase}' has no heartbeat for ${age}s"
      elif (( SECONDS > deadline )); then
        echo "ERROR: job ${owner} is running phase '${phase}' on the hypervisor (heartbeat ${age}s ago)"
        return 1
      else
        echo "Waiting for job ${owner} (phase ${phase}, heartbeat ${age}s ago) to finish..."
        sleep 20
        continue
      fi
    fi
    # Reclaim: stop what the previous owner left behind so it stops using the
    # cluster before this phase starts.
    if [[ -n "${container}" && "${container}" != "${CONTAINER}" ]]; then
      hv_ssh "podman rm -f ${container} >/dev/null 2>&1 || true"
    fi
    session_lock_write
    return 0
  done
  session_lock_write
}

session_heartbeat_start() {
  (
    while true; do
      hv_ssh "date +%s > ${SESSION_HEARTBEAT}" >/dev/null 2>&1 || true
      sleep 20
    done
  ) &
  SESSION_HEARTBEAT_PID=$!
}

session_heartbeat_stop() {
  if [[ -n "${SESSION_HEARTBEAT_PID:-}" ]]; then
    kill "${SESSION_HEARTBEAT_PID}" 2>/dev/null || true
    wait "${SESSION_HEARTBEAT_PID}" 2>/dev/null || true
  fi
}

session_lock_release() {
  session_heartbeat_stop
  if [[ "$(session_field job)" == "${JOB_ID}" ]]; then
    hv_ssh "rm -f ${SESSION_LOCK} ${SESSION_HEARTBEAT}" >/dev/null 2>&1 || true
  fi
}

trap 'session_lock_release || true' EXIT
step_marker "Acquire the PTP session lock"
session_lock_acquire || exit 1
session_heartbeat_start

step_marker "Prepare the gather image"
hv_ssh "command -v podman >/dev/null 2>&1" || { echo "ERROR: hypervisor is missing podman"; exit 1; }
hv_ssh "podman image exists registry.ci.openshift.org/ci/telco-runner:latest >/dev/null 2>&1 || podman pull registry.ci.openshift.org/ci/telco-runner:latest >/dev/null 2>&1" \
  || { echo "ERROR: unable to pull the telco-runner image on the hypervisor"; exit 1; }

step_marker "Reuse the test runner artifacts"
# Reuse the test runner's shared directory and artifacts. If the test step did
# not create them, seed from the CI SHARED_DIR.
if ! hv_ssh "test -f ~/runner/shared/kubeconfig"; then
  hv_ssh "mkdir -p ~/runner/shared ~/runner/artifacts"
  tar -C "$SHARED_DIR" -cf - . | hv_ssh "tar -C ~/runner/shared -xf -"
fi
hv_ssh "mkdir -p ~/runner/artifacts ~/runner/output"

cat >/tmp/gather.sh <<'GATHER'
#!/bin/bash
set -o nounset
set -o pipefail
if [[ -f /runner/shared/ci.env ]]; then
  # shellcheck source=/dev/null
  source /runner/shared/ci.env
fi
export SHARED_DIR=/runner/shared
export ARTIFACT_DIR=/runner/artifacts
export KUBECONFIG=/runner/shared/kubeconfig
# The standard gather-must-gather uses ${EXTRA_MG_ARGS} under `set -u`
# without initializing it when no custom must-gather image is requested.
export EXTRA_MG_ARGS=""

# Emit a machine-readable step marker for log scrapers. The timestamp is UTC.
step_marker() {
  local timestamp
  timestamp="$(date -u +%Y-%m-%dT%H:%M:%SZ)"
  printf '[STEP] %s - %s\n' "${timestamp}" "$*"
}

step_marker "Clone the release repository for gather scripts"
git clone --depth 1 https://github.com/openshift/release /runner/release || { echo "release clone failed"; exit 0; }
# Bound the clusteroperators inspect: it can hang even when the API is healthy.
GATHER_EXTRA=/runner/release/ci-operator/step-registry/gather/extra/gather-extra-commands.sh
sed -i 's@^\(oc --insecure-skip-tls-verify --request-timeout=5s adm inspect clusteroperators\)@timeout 180s \1@' "$GATHER_EXTRA" || true
step_marker "Run must-gather"
bash /runner/release/ci-operator/step-registry/gather/must-gather/gather-must-gather-commands.sh || true
step_marker "Run gather-extra"
bash /runner/release/ci-operator/step-registry/gather/extra/gather-extra-commands.sh || true
step_marker "Collect the audit logs"
bash /runner/release/ci-operator/step-registry/gather/audit-logs/gather-audit-logs-commands.sh || true
step_marker "Gather container finished"
GATHER
hv_ssh "cat > ~/runner/gather.sh" < /tmp/gather.sh

step_marker "Seed a writable output directory"
if ! hv_ssh "test -d ~/runner/output/golang-1.22.4"; then
  hv_ssh "podman run --rm --replace --name telco5g-ptp-gather-seed --userns=keep-id --entrypoint /bin/bash -v ~/runner/output:/dest:Z registry.ci.openshift.org/ci/telco-runner:latest -c 'cp -r /output/. /dest/ && chown -R 1000:1000 /dest'"
fi

step_marker "Run the gather container"
hv_ssh "podman run --rm --replace --name telco5g-ptp-gather --net=host --userns=keep-id --entrypoint /bin/bash -v ~/runner/output:/output:Z -v ~/runner:/runner:Z -e MUST_GATHER_TIMEOUT=35m -w /runner registry.ci.openshift.org/ci/telco-runner:latest /runner/gather.sh" || true

step_marker "Collect the gather artifacts"
mkdir -p "$ARTIFACT_DIR"
# Copy only the gathered archives and PTP result files. The full artifacts tree
# is several GB (metrics alone is >2 GB) and streaming it uncompressed over the
# bastion exceeded the step budget; pod logs are already uploaded by the test
# step.
GATHER_ARTIFACTS=(must-gather.tar.gz audit-logs.tar.gz event-filter.html camgi.html
  test_results.json test_results_all.html test_results_*.xml)
if hv_ssh "test -d ~/runner/artifacts"; then
  hv_ssh "cd ~/runner/artifacts && timeout 20m tar -czf - --ignore-failed-read ${GATHER_ARTIFACTS[*]} 2>/dev/null" \
    | tar -C "$ARTIFACT_DIR" -xzf - || true
fi

step_marker "PTP gather complete"
