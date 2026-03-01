#!/bin/bash

set -eu

# Exit code we will use at end (so EXIT trap can reliably know if we failed)
SCRIPT_EXIT_CODE=0

# Cluster credentials from install step (ipi-aws writes kubeadmin-password to SHARED_DIR)
if [[ -n "${SHARED_DIR:-}" && -s "${SHARED_DIR}/kubeadmin-password" ]]; then
  export KUBEADMIN_PASSWORD=$(cat "${SHARED_DIR}/kubeadmin-password")
fi

# Use cluster kubeconfig so oc and make deploy (kubectl) both target the test cluster
if [[ -f /var/run/secrets/ci.openshift.io/multi-stage/kubeconfig ]]; then
  cp /var/run/secrets/ci.openshift.io/multi-stage/kubeconfig /tmp/kubeconfig
  export KUBECONFIG=/tmp/kubeconfig
fi

# Writable copy of benchmark-operator so make deploy can write bin/ and use kustomize (image has read-only /tmp/benchmark-operator and no which).
RUNNER_ROOT=/tmp/benchmark-runner-deploy
mkdir -p "$RUNNER_ROOT"
cp -r /tmp/benchmark-operator "$RUNNER_ROOT/"
export RUNNER_PATH="$RUNNER_ROOT"

# Pre-download kustomize so Makefile does not need which/mkdir/download at runtime (avoids permission and missing-which failures).
KUSTOMIZE_VERSION=3.5.4
BIN_DIR="$RUNNER_PATH/benchmark-operator/bin"
mkdir -p "$BIN_DIR"
curl -sL "https://github.com/kubernetes-sigs/kustomize/releases/download/kustomize%2Fv${KUSTOMIZE_VERSION}/kustomize_v${KUSTOMIZE_VERSION}_linux_amd64.tar.gz" | tar -C "$BIN_DIR" -xz
chmod +x "$BIN_DIR/kustomize"
# Shim for "which" so Makefile's $(shell which kustomize) works (image has no which binary)
echo '#!/bin/sh
command -v "$@"' > "$BIN_DIR/which"
chmod +x "$BIN_DIR/which"
export PATH="$BIN_DIR:$PATH"

# Workaround for benchmark-runner: pod_exists and _get_pod_name use "oc get pods -o name | grep ..."; subprocess.getoutput() ignores grep exit code so pod is never seen. Replace with jsonpath in both places so CI passes. Root fix belongs in benchmark-runner.
PATCH_OC=$(python3.14 -c "import benchmark_runner.common.oc.oc as m; print(m.__file__)" 2>/dev/null) || true
PATCH_APPLIED=0
if [[ -n "${PATCH_OC:-}" && -f "$PATCH_OC" ]]; then
  PACKAGE_ROOT=$(cd "$(dirname "$PATCH_OC")/../.." && pwd)
  rm -rf /tmp/benchmark_runner
  cp -r "$PACKAGE_ROOT" /tmp/benchmark_runner 2>/dev/null || true
  if [[ -f /tmp/benchmark_runner/common/oc/oc.py ]]; then
    if python3.14 << 'PYEOF'; then
import sys
path = '/tmp/benchmark_runner/common/oc/oc.py'
old = ' -o name | grep {pod_name}'
# Use single quotes around jsonpath so the shell does not expand * or {} when run via subprocess
new = " -o jsonpath=\\'{{.items[*].metadata.name}}\\'"
with open(path) as f:
    content = f.read()
n = content.count(old)
if n == 0:
    sys.exit(1)
content = content.replace(old, new)
if content.count(old) != 0:
    sys.exit(2)
with open(path, 'w') as f:
    f.write(content)
PYEOF
      # Force Python to load patched source: remove all bytecode cache under patched package
      find /tmp/benchmark_runner -type d -name __pycache__ -exec rm -rf {} + 2>/dev/null || true
      export PYTHONPATH=/tmp${PYTHONPATH:+:$PYTHONPATH}
      # Verify both call sites were patched (file on disk); with PYTHONPATH=/tmp, main.py will load this file
      if grep -q ' -o name | grep {pod_name}' /tmp/benchmark_runner/common/oc/oc.py 2>/dev/null || \
         ! grep -q 'jsonpath.*metadata\.name' /tmp/benchmark_runner/common/oc/oc.py 2>/dev/null; then
        echo "FATAL: oc.py patch verification failed (old pattern still present or jsonpath missing). Would hit PodNotCreateTimeout. Exiting."
        exit 1
      fi
      echo "Verified: oc.py patched (jsonpath in place, grep pattern removed)"
      PATCH_APPLIED=1
      echo "Patched both pod_exists and _get_pod_name in oc.py at /tmp/benchmark_runner (workaround for benchmark-runner)"
    else
      echo "Warning: oc.py patch failed (pattern not found or replace failed)"
    fi
  else
    echo "Warning: could not copy benchmark_runner package to /tmp/benchmark_runner"
  fi
  if [[ $PATCH_APPLIED -eq 0 ]]; then
    echo "FATAL: Could not apply pod_exists workaround. CI would hit PodNotCreateTimeout after ~66min. Exiting now."
    exit 1
  fi
fi

# Debug: poll what oc sees in benchmark-operator namespace (same check Python's pod_exists uses). Log to file and stop on exit.
POLL_LOG="${ARTIFACT_DIR:-/tmp}/benchmark-operator-oc-poll.log"
oc_poll_loop() {
  while true; do
    {
      echo "=== $(date -Iseconds) ==="
      echo "--- oc get pods -o name ---"
      oc get pods -n benchmark-operator -o name 2>&1 || true
      echo "--- Python's check: oc get pods -o name | grep benchmark-controller-manager (exit 0=found 1=not) ---"
      grep_ret=1
      out=$(oc get pods -n benchmark-operator -o name 2>&1 | grep benchmark-controller-manager) && grep_ret=0 || true
      echo "$out"
      echo "grep_exit: $grep_ret"
      echo "--- deployments ---"
      oc get deployment -n benchmark-operator 2>&1 || true
    } >> "$POLL_LOG" 2>&1
    sleep 30
  done
}
oc_poll_loop &
POLL_PID=$!

# Dump benchmark-operator namespace state on exit when something failed (runs before exit so it appears in logs even if container is killed after Python exits).
benchmark_operator_debug() {
  local _code=$?
  kill "${POLL_PID:-}" 2>/dev/null || true
  if [[ $_code -ne 0 || "${SCRIPT_EXIT_CODE:-0}" -ne 0 ]]; then
    echo "=== benchmark-operator oc poll log (what oc saw during run) ==="
    cat "$POLL_LOG" 2>/dev/null || true
    echo "=== benchmark-operator namespace state (debug, on exit) ==="
    oc get all -n benchmark-operator 2>&1 || true
    echo "=== benchmark-operator events (debug, on exit) ==="
    oc get events -n benchmark-operator 2>&1 || true
  fi
}
trap benchmark_operator_debug EXIT

# Ensure benchmark-operator namespace exists (kustomize does not create it; without it make deploy never creates the controller pod)
oc create namespace benchmark-operator 2>/dev/null || true

# One-time snapshot before Python (same namespace/oc that Python will use).
echo "=== KUBECONFIG (script env for oc) ==="
echo "KUBECONFIG=${KUBECONFIG:-<unset>}"
if [[ -n "${KUBECONFIG:-}" ]]; then
  test -f "$KUBECONFIG" && echo "kubeconfig_file: exists" || echo "kubeconfig_file: missing"
fi
echo "=== Python start time: $(date -Iseconds) ==="
echo "=== benchmark-operator before Python (oc get pods -o name) ==="
oc get pods -n benchmark-operator -o name 2>&1 || true
echo "=== benchmark-operator deployments before Python ==="
oc get deployment -n benchmark-operator 2>&1 || true

# Do not run make deploy here. Python runs make_undeploy_if_exist then make deploy; a prior script deploy causes Python to undeploy and redeploy, and wait_for_pod_create can fail to see the new pod. Single deploy by Python only.

# When we applied the oc.py workaround, run main from the patched package so Python only loads benchmark_runner from /tmp (avoids import-order races and stale bytecode).
if [[ -f /tmp/benchmark_runner/main/main.py ]]; then
  PYTHONPATH=/tmp python3.14 /tmp/benchmark_runner/main/main.py
else
  python3.14 /benchmark_runner/main/main.py
fi
rc=$?
SCRIPT_EXIT_CODE=$rc
echo "=== Python end time: $(date -Iseconds) exit_code: $rc ==="
# Snapshot right after Python: same check Python's pod_exists uses (did script's oc see the pod at exit?).
echo "=== benchmark-operator right after Python (oc get pods -o name) ==="
oc get pods -n benchmark-operator -o name 2>&1 || true
echo "=== Python's check after Python: oc get pods -o name | grep benchmark-controller-manager ==="
grep_ret=1
out=$(oc get pods -n benchmark-operator -o name 2>&1 | grep benchmark-controller-manager) && grep_ret=0 || true
echo "$out"
echo "grep_exit: $grep_ret (0=pod seen by script's oc 1=not)"
# Always dump to build log (stdout) right after Python returns, so it appears in build-log.txt.
echo "=== benchmark-operator namespace state (debug) ==="
oc get all -n benchmark-operator 2>&1 || true
echo "=== benchmark-operator events (debug) ==="
oc get events -n benchmark-operator 2>&1 || true
if [ $rc -ne 0 ] && [[ -n "${ARTIFACT_DIR:-}" ]]; then
  mkdir -p "${ARTIFACT_DIR}/benchmark-operator-debug"
  oc get all -n benchmark-operator > "${ARTIFACT_DIR}/benchmark-operator-debug/all.yaml" 2>&1 || true
  oc get events -n benchmark-operator > "${ARTIFACT_DIR}/benchmark-operator-debug/events.txt" 2>&1 || true
  oc get deployment benchmark-controller-manager -n benchmark-operator -o yaml > "${ARTIFACT_DIR}/benchmark-operator-debug/deployment-controller-manager.yaml" 2>&1 || true
  cp "$POLL_LOG" "${ARTIFACT_DIR}/benchmark-operator-debug/oc-poll.log" 2>/dev/null || true
fi
echo "benchmark-runner exit code: $rc"
exit $SCRIPT_EXIT_CODE
