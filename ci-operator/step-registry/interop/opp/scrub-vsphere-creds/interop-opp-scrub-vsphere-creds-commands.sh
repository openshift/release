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
# Keep credentials out of arguments and replace exact byte sequences so regex
# metacharacters are always treated literally.
scrubbed=$(
  SCRUB_PASSWORD="${govc_password}" \
  SCRUB_USERNAME="${govc_username}" \
  SCRUB_MARKER="${REDACT_MARKER}" \
  python3 - <<'PYTHON'
import os
import stat

shared_dir = os.environb[b"SHARED_DIR"]
secrets = tuple(
    value
    for value in (
        os.environb[b"SCRUB_PASSWORD"],
        os.environb[b"SCRUB_USERNAME"],
    )
    if value
)
marker = os.environb[b"SCRUB_MARKER"]
scrubbed = 0

for directory, subdirectories, filenames in os.walk(shared_dir):
    relative_directory = os.path.relpath(directory, shared_dir)
    depth = 0 if relative_directory == b"." else relative_directory.count(b"/") + 1
    if depth >= 3:
        subdirectories.clear()
        continue

    for filename in filenames:
        path = os.path.join(directory, filename)
        try:
            if not stat.S_ISREG(os.stat(path, follow_symlinks=False).st_mode):
                continue
            with open(path, "rb") as stream:
                original = stream.read()
            redacted = original
            for secret in secrets:
                redacted = redacted.replace(secret, marker)
            if redacted == original:
                continue
            with open(path, "wb") as stream:
                stream.write(redacted)
            with open(path, "rb") as stream:
                verified = stream.read()
            if any(secret in verified for secret in secrets):
                raise RuntimeError("credential redaction verification failed")
            scrubbed += 1
        except OSError:
            continue

print(scrubbed)
PYTHON
)

echo ">>> interop-opp-scrub-vsphere-creds: scrubbed credentials from ${scrubbed} file(s) in \${SHARED_DIR}"
exit 0
