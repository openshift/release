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

# ---------- scrub credential values from all files ----------
# Disable tracing so we never log credentials.
set +x

REDACT_MARKER="***REDACTED***"
# Read assignments without sourcing them so shell metacharacters stay literal.
scrubbed=$(
  SCRUB_MARKER="${REDACT_MARKER}" \
  python3 - <<'PYTHON'
import os
import re
import stat

shared_dir = os.environb[b"SHARED_DIR"]
marker = os.environb[b"SCRUB_MARKER"]
assignment = re.compile(
    rb"^[ \t]*(?:export[ \t]+)?(?:GOVC_PASSWORD|GOVC_USERNAME)=([^\r\n]*)\r?$",
    re.MULTILINE,
)
credential_files = set()
secrets = set()
scrubbed = 0

with os.scandir(shared_dir) as entries:
    for entry in entries:
        name = entry.name
        is_generated_govc = name == b"govc.sh" or (
            name.startswith(b"govc_") and name.endswith(b".sh")
        )
        is_credential_context = name in (b"vsphere_context.sh", b"vsphere_info.json")
        if not (is_generated_govc or is_credential_context):
            continue
        try:
            if not entry.is_file(follow_symlinks=False):
                continue
            credential_files.add(entry.path)
            if not name.endswith(b".sh"):
                continue
            with open(entry.path, "rb") as stream:
                contents = stream.read()
            for match in assignment.finditer(contents):
                value = match.group(1)
                if len(value) >= 2 and value[:1] == value[-1:] and value[:1] in (b"'", b'"'):
                    value = value[1:-1]
                if value:
                    secrets.add(value)
        except OSError:
            continue

# Replace longer values first when one credential contains another.
secrets = tuple(sorted(secrets, key=len, reverse=True))

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

# These files exist only to pass credentials between vSphere consumers. The
# scrub step runs after the post chain, so remove them before artifact upload.
for path in credential_files:
    try:
        os.remove(path)
    except FileNotFoundError:
        continue
    except OSError:
        pass

    try:
        os.lstat(path)
    except FileNotFoundError:
        continue
    except OSError:
        pass
    raise SystemExit("ERROR: credential file remains before artifact upload")

print(scrubbed)
PYTHON
)

echo ">>> interop-opp-scrub-vsphere-creds: scrubbed credentials from ${scrubbed} file(s) in \${SHARED_DIR}"
exit 0
