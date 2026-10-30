#!/bin/bash

set -o nounset
set -o errexit
set -o pipefail

if [[ ! -f "${SHARED_DIR}/kubeconfig" ]]; then
  echo "ERROR: ${SHARED_DIR}/kubeconfig not found; cluster install may have failed"
  exit 1
fi

export KUBECONFIG="${SHARED_DIR}/kubeconfig"

# Wait for the console route to be available (libvirt clusters can be slow)
echo "Waiting for openshift-console route to become available..."
for i in $(seq 1 30); do
  CONSOLE_HOST=$(oc -n openshift-console get route console -o jsonpath='{.spec.host}' 2>/dev/null || true)
  if [[ -n "${CONSOLE_HOST}" ]]; then
    echo "Console route found: ${CONSOLE_HOST}"
    break
  fi
  echo "Attempt ${i}/30: console route not yet available, retrying in 10s..."
  sleep 10
done

if [[ -z "${CONSOLE_HOST}" ]]; then
  echo "ERROR: openshift-console route was not available after 5 minutes"
  exit 1
fi

echo "https://${CONSOLE_HOST}" > "${SHARED_DIR}/console.url"
echo "Written to \${SHARED_DIR}/console.url: $(cat "${SHARED_DIR}/console.url")"
