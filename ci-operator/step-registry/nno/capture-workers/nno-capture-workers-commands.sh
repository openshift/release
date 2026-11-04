#!/bin/bash
set +x
set -euo pipefail

for marker in skip-work-steps skip-nno-precompiled; do
  if [[ -f "${SHARED_DIR}/${marker}" ]]; then
    echo "Skipping worker inventory capture: ${marker} is present."
    exit 0
  fi
done
if [[ -f "${SHARED_DIR}/proxy-conf.sh" ]]; then
  # shellcheck source=/dev/null
  source "${SHARED_DIR}/proxy-conf.sh" >/dev/null 2>&1 || {
    echo "ERROR: Could not load proxy configuration" >&2; exit 1;
  }
  set +x
fi

# Fail before changing firmware if the installed worker inventory cannot be read.
# Raw API diagnostics can contain internal names and URLs.
worker_names="$(oc --request-timeout=30s get nodes -l node-role.kubernetes.io/worker -o jsonpath='{.items[*].metadata.name}' 2>/dev/null)" || {
  echo "ERROR: Could not read worker inventory before firmware transition" >&2; exit 1;
}
[[ -n "${worker_names}" ]] || { echo "ERROR: No worker nodes found before firmware transition" >&2; exit 1; }
printf '%s\n' "${worker_names}" > "${SHARED_DIR}/nno-expected-workers"
echo "Recorded worker inventory before firmware transition."
