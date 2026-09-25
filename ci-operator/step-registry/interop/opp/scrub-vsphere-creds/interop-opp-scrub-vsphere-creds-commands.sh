#!/bin/bash
#
# Scrub vSphere credentials from $SHARED_DIR before ci-operator uploads
# the directory contents to GCS as publicly-accessible artifacts.
#
# The ipi-conf-vsphere-check (and its vcm sibling) step writes govc.sh
# into $SHARED_DIR with plaintext GOVC_PASSWORD / GOVC_USERNAME values.
# Other steps may propagate these values into install-config.yaml,
# ocs-ci config files, or other artifacts.  This post-step replaces
# every occurrence of the actual credential values with a redaction
# marker so that nothing sensitive survives into the uploaded artifacts.

set -euo pipefail

echo ">>> interop-opp-scrub-vsphere-creds: starting credential scrub of \${SHARED_DIR}"

# ---------- locate govc.sh ----------

govc_sh="${SHARED_DIR}/govc.sh"
if [[ ! -f "${govc_sh}" ]]; then
  echo "INFO: ${govc_sh} not found -- nothing to scrub (non-vSphere job?)"
  exit 0
fi

# ---------- extract credential values ----------
# Disable tracing so we never log the password.
set +x

# Source govc.sh in a subshell to capture GOVC_PASSWORD and GOVC_USERNAME
# without polluting the current environment beyond what we need.
govc_password=$(bash -c 'source "'"${govc_sh}"'" 2>/dev/null; echo "${GOVC_PASSWORD:-}"')
govc_username=$(bash -c 'source "'"${govc_sh}"'" 2>/dev/null; echo "${GOVC_USERNAME:-}"')

if [[ -z "${govc_password}" ]]; then
  echo "INFO: GOVC_PASSWORD is empty after sourcing govc.sh -- nothing to scrub"
  exit 0
fi

# ---------- scrub credential values from all files ----------
REDACT_MARKER="***REDACTED***"
scrubbed=0

# Build a list of files that contain the password value.
# grep -r on binary-safe mode; skip non-text files gracefully.
matching_files=()
while IFS= read -r -d '' fpath; do
  # Only process regular files
  [[ -f "${fpath}" ]] || continue
  # Use grep -F (fixed string) to avoid regex interpretation of the password
  if grep -qF -- "${govc_password}" "${fpath}" 2>/dev/null; then
    matching_files+=("${fpath}")
  fi
done < <(find "${SHARED_DIR}" -maxdepth 3 -type f -print0 2>/dev/null)

for fpath in "${matching_files[@]}"; do
  # Build a sed-safe replacement: escape sed special chars in the password
  # (the password could contain /, &, \, etc.)
  escaped_pw=$(printf '%s\n' "${govc_password}" | sed 's/[&/\]/\\&/g')
  if sed -i "s/${escaped_pw}/${REDACT_MARKER}/g" "${fpath}" 2>/dev/null; then
    scrubbed=$((scrubbed + 1))
  fi
done

# Also scrub the username if present (less critical but good hygiene)
if [[ -n "${govc_username}" ]]; then
  for fpath in "${matching_files[@]}"; do
    escaped_user=$(printf '%s\n' "${govc_username}" | sed 's/[&/\]/\\&/g')
    sed -i "s/${escaped_user}/${REDACT_MARKER}/g" "${fpath}" 2>/dev/null || true
  done
  # Check for username in files that didn't have the password
  while IFS= read -r -d '' fpath; do
    [[ -f "${fpath}" ]] || continue
    if grep -qF -- "${govc_username}" "${fpath}" 2>/dev/null; then
      escaped_user=$(printf '%s\n' "${govc_username}" | sed 's/[&/\]/\\&/g')
      sed -i "s/${escaped_user}/${REDACT_MARKER}/g" "${fpath}" 2>/dev/null || true
      scrubbed=$((scrubbed + 1))
    fi
  done < <(find "${SHARED_DIR}" -maxdepth 3 -type f -print0 2>/dev/null)
fi

echo ">>> interop-opp-scrub-vsphere-creds: scrubbed credentials from ${scrubbed} file(s) in \${SHARED_DIR}"
exit 0
