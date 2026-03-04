#!/bin/bash

set -euo pipefail

# Exit code we will use at end (so EXIT trap can reliably know if we failed)
SCRIPT_EXIT_CODE=0

# Cluster credentials from install step (ipi-aws writes kubeadmin-password to SHARED_DIR)
if [[ -n "${SHARED_DIR:-}" && -s "${SHARED_DIR}/kubeadmin-password" ]]; then
  KUBEADMIN_PASSWORD=$(cat "${SHARED_DIR}/kubeadmin-password")
  export KUBEADMIN_PASSWORD
fi

# Use cluster kubeconfig so oc targets the test cluster
if [[ -f /var/run/secrets/ci.openshift.io/multi-stage/kubeconfig ]]; then
  cp /var/run/secrets/ci.openshift.io/multi-stage/kubeconfig /tmp/kubeconfig
  export KUBECONFIG=/tmp/kubeconfig
fi

# Optional: load config from Vault-mounted secret (selfservice/perfci/benchmark-runner)
if [[ -d /secret ]]; then
  echo "=== Vault secret mounted at /secret (keys below) ==="
  ls -la /secret 2>/dev/null || true
  if [[ -s /secret/base_domain ]]; then
    BASE_DOMAIN=$(cat /secret/base_domain)
    export BASE_DOMAIN
  fi
  # Add other keys here as needed (e.g. elasticsearch, tokens)
fi

# Workaround for benchmark-runner: pod_exists and _get_pod_name use "oc get pods -o name | grep ...";
# subprocess.getoutput() ignores grep exit code so pod is never seen.
# Replace with jsonpath in both places so CI passes. Root fix belongs in benchmark-runner.
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
      # Inject debug: print what pod_exists() sees so build log shows why Python might return False
      python3.14 << 'PYEOF2'
import sys
path = '/tmp/benchmark_runner/common/oc/oc.py'
with open(path) as f:
    content = f.read()
old = "        if pod_name in result:\n            return True"
debug = """        import sys
        print(f'[pod_exists] namespace={namespace!r} pod_name={pod_name!r} result={result!r} len={len(result)}', flush=True)
        sys.stdout.flush()
        if pod_name in result:
            return True"""
if old not in content:
    sys.exit(3)
content = content.replace(old, debug, 1)
with open(path, 'w') as f:
    f.write(content)
PYEOF2
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

# Dump benchmark-runner namespace state on exit when something failed.
benchmark_runner_debug() {
  local _code=$?
  if [[ $_code -ne 0 || "${SCRIPT_EXIT_CODE:-0}" -ne 0 ]]; then
    echo "=== benchmark-runner namespace state (debug, on exit) ==="
    oc get all -n benchmark-runner 2>&1 || true
    echo "=== benchmark-runner events (debug, on exit) ==="
    oc get events -n benchmark-runner 2>&1 || true
  fi
}
trap benchmark_runner_debug EXIT

# Ensure benchmark-runner namespace exists on the TEST cluster
oc create namespace benchmark-runner 2>/dev/null || true

echo "=== Python start: $(date -Iseconds) ==="

# When we applied the oc.py workaround, run main from the patched package so Python only loads benchmark_runner from /tmp (avoids import-order races and stale bytecode).
if [[ -f /tmp/benchmark_runner/main/main.py ]]; then
  python3.14 /tmp/benchmark_runner/main/main.py
else
  python3.14 /benchmark_runner/main/main.py
fi
rc=$?
SCRIPT_EXIT_CODE=$rc
echo "=== Python end: $(date -Iseconds) exit_code: $rc ==="
if [ $rc -ne 0 ] && [[ -n "${ARTIFACT_DIR:-}" ]]; then
  mkdir -p "${ARTIFACT_DIR}/benchmark-runner-debug"
  oc get all -n benchmark-runner > "${ARTIFACT_DIR}/benchmark-runner-debug/all.yaml" 2>&1 || true
  oc get events -n benchmark-runner > "${ARTIFACT_DIR}/benchmark-runner-debug/events.txt" 2>&1 || true
fi
echo "benchmark-runner exit code: $rc"
exit $SCRIPT_EXIT_CODE
