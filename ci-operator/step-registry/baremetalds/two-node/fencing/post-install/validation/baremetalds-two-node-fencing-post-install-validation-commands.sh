#!/usr/bin/env bash
set -euo pipefail

echo "[INFO] Starting baremetalds-two-node-fencing-post-install-validation step"

if [[ "${FENCING_VALIDATION:-false}" != "true" ]]; then
  echo "[INFO] FENCING_VALIDATION != true; skipping fencing_validator execution."
  exit 0
fi

ARTIFACT_DIR="${ARTIFACT_DIR:-/tmp}"

echo "[INFO] Detecting control-plane nodes (label: node-role.kubernetes.io/control-plane)…"
NODE="$(oc get nodes -l node-role.kubernetes.io/control-plane= -o jsonpath='{.items[0].metadata.name}' || true)"

if [[ -z "${NODE}" ]]; then
  echo "[WARN] No nodes found with label node-role.kubernetes.io/control-plane, falling back to node-role.kubernetes.io/master…"
  NODE="$(oc get nodes -l node-role.kubernetes.io/master= -o jsonpath='{.items[0].metadata.name}' || true)"
fi

if [[ -z "${NODE}" ]]; then
  echo "[ERROR] No control-plane or master nodes found, cannot fetch fencing_validator."
  echo "[INFO] Current node list for debugging:"
  oc get nodes -o wide || true
  exit 1
fi

echo "[INFO] Selected node for fetching script: ${NODE}"

LOCAL_SCRIPT="$(mktemp /tmp/fencing_validator.XXXXXX)"
echo "[INFO] Copying /usr/local/bin/fencing_validator from ${NODE} to ${LOCAL_SCRIPT}…"

if ! oc debug -n default "node/${NODE}" -- chroot /host cat /usr/local/bin/fencing_validator > "${LOCAL_SCRIPT}"; then
  echo "[ERROR] Failed to copy fencing_validator from ${NODE}. Is it installed at /usr/local/bin/fencing_validator on the host?"
  exit 1
fi

chmod +x "${LOCAL_SCRIPT}"

echo "[INFO] Setting oc project to 'default' for fencing_validator ocdebug…"
if ! oc project default >/dev/null 2>&1; then
  echo "[WARN] Failed to set oc project to 'default'; oc debug inside fencing_validator may fail if the current namespace does not exist on the target cluster."
fi

LOG_NON_DISRUPTIVE="${ARTIFACT_DIR}/fencing-validator-non-disruptive.log"
LOG_DISRUPTIVE="${ARTIFACT_DIR}/fencing-validator-disruptive.log"

# Non-disruptive validation (run from tests pod, transport=ocdebug)
echo "[INFO] Running non-disruptive fencing_validator (transport=ocdebug)…"
set +e
TRANSPORT=ocdebug "${LOCAL_SCRIPT}" \
  --timeout 1800 2>&1 | tee "${LOG_NON_DISRUPTIVE}"
RC_NON_DISRUPTIVE="${PIPESTATUS[0]}"
set -e

echo "[INFO] fencing_validator (non-disruptive) exit code: ${RC_NON_DISRUPTIVE}"
if [[ "${RC_NON_DISRUPTIVE}" -ne 0 ]]; then
  echo "[ERROR] Non-disruptive fencing_validator run failed with code ${RC_NON_DISRUPTIVE}."
  echo "[INFO] See ${LOG_NON_DISRUPTIVE} for full validator output."
  exit "${RC_NON_DISRUPTIVE}"
fi

# Optional disruptive validation
if [[ "${DISRUPTIVE_FENCING:-false}" == "true" ]]; then
  echo "[INFO] DISRUPTIVE_FENCING=true; running disruptive fencing_validator (transport=ocdebug)…"
  set +e
  TRANSPORT=ocdebug "${LOCAL_SCRIPT}" \
    --timeout 1800 --disruptive 2>&1 | tee "${LOG_DISRUPTIVE}"
  RC_DISRUPTIVE="${PIPESTATUS[0]}"
  set -e

  echo "[INFO] fencing_validator (disruptive) exit code: ${RC_DISRUPTIVE}"
  if [[ "${RC_DISRUPTIVE}" -ne 0 ]]; then
    echo "[ERROR] Disruptive fencing_validator run failed with code ${RC_DISRUPTIVE}."
    echo "[INFO] See ${LOG_DISRUPTIVE} for full validator output."
    exit "${RC_DISRUPTIVE}"
  fi
else
  echo "[INFO] DISRUPTIVE_FENCING!=true; skipping disruptive fencing run."
fi

echo "[INFO] fencing_validator step completed successfully."
