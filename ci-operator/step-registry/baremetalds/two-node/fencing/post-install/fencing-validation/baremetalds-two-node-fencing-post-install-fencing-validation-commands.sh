#!/usr/bin/env bash
set -euo pipefail

echo "[INFO] Starting baremetalds-two-node-fencing-post-install-node-fencing-validation step"

if [[ "${FENCING_VALIDATION:-false}" != "true" ]]; then
  echo "[INFO] FENCING_VALIDATION != true; skipping fencing_validator execution."
  exit 0
fi

# Pick a control-plane node just to read the script from
NODE="$(oc get nodes -l node-role.kubernetes.io/control-plane= -o jsonpath='{.items[0].metadata.name}')"
if [[ -z "${NODE}" ]]; then
  echo "[ERROR] No control-plane nodes found, cannot fetch fencing_validator."
  exit 1
fi
echo "[INFO] Selected node for fetching script: ${NODE}"

LOCAL_SCRIPT="/tmp/fencing_validator"
echo "[INFO] Copying /usr/local/bin/fencing_validator from ${NODE} to ${LOCAL_SCRIPT}…"

oc debug -n default "node/${NODE}" -- chroot /host cat /usr/local/bin/fencing_validator > "${LOCAL_SCRIPT}"
chmod +x "${LOCAL_SCRIPT}"

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
    exit "${RC_DISRUPTIVE}"
  fi
else
  echo "[INFO] DISRUPTIVE_FENCING!=true; skipping disruptive fencing run."
fi

echo "[INFO] fencing_validator step completed successfully."
