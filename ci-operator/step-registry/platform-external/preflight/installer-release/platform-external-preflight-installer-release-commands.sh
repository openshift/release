#!/bin/bash

#
# Preflight: verify bootstrap ignition CVO render flags are accepted by the
# install release payload before provisioning cloud resources.
#
# Root cause this guards: newer installer embeds
#   --cluster-version-manifest-path
# in bootkube.sh, but older release CVO binaries reject unknown flags and
# exit during cvo-bootstrap (API never comes up).
#

set -o nounset
set -o errexit
set -o pipefail

if [[ -n "${PLATFORM_EXTERNAL_OVERRIDE_RELEASE-}" ]]; then
  export OPENSHIFT_INSTALL_RELEASE_IMAGE_OVERRIDE="${PLATFORM_EXTERNAL_OVERRIDE_RELEASE}"
fi

# Prefer the release image recorded by the manifests step (exact payload in ignition).
RELEASE_IMAGE_FILE="${SHARED_DIR}/platform-external-install-release-image"
if [[ -f "${RELEASE_IMAGE_FILE}" ]]; then
  RELEASE_IMAGE="$(<"${RELEASE_IMAGE_FILE}")"
else
  RELEASE_IMAGE="${OPENSHIFT_INSTALL_RELEASE_IMAGE_OVERRIDE:-}"
fi
BOOTSTRAP_IGN="${SHARED_DIR}/bootstrap.ign"
# Same auth pattern as platform-external-pre-conf / manifests extract.
PULL_SECRET="${REGISTRY_AUTH_FILE:-/tmp/secret/pull-secret-with-ci}"
ARTIFACT_LOG="${ARTIFACT_DIR}/preflight-installer-release.log"

mkdir -p "${ARTIFACT_DIR}"
mkdir -p "$(dirname "${PULL_SECRET}")"
exec > >(tee -a "${ARTIFACT_LOG}") 2>&1

echo "=== platform-external preflight: installer/bootstrap vs install release ==="
echo "install release image (for CVO check)=${RELEASE_IMAGE}"
echo "OPENSHIFT_INSTALL_RELEASE_IMAGE_OVERRIDE=${OPENSHIFT_INSTALL_RELEASE_IMAGE_OVERRIDE:-}"

if [[ -z "${RELEASE_IMAGE}" ]]; then
  echo "ERROR: install release image is empty (manifests step should write ${RELEASE_IMAGE_FILE})"
  exit 1
fi

if [[ ! -f "${BOOTSTRAP_IGN}" ]]; then
  echo "ERROR: ${BOOTSTRAP_IGN} not found; manifests/ignition step must run first"
  exit 1
fi

if [[ ! -f "${CLUSTER_PROFILE_DIR}/pull-secret" ]]; then
  echo "ERROR: pull secret not found at ${CLUSTER_PROFILE_DIR}/pull-secret"
  exit 1
fi

cp -f "${CLUSTER_PROFILE_DIR}/pull-secret" "${PULL_SECRET}"
if [[ "$(dirname "$(dirname "${RELEASE_IMAGE}")")" != "quay.io" ]]; then
  echo "Logging into CI registry for release/CVO image pulls"
  KUBECONFIG="" oc registry login --to "${PULL_SECRET}"
fi

FLAG_CHECK_SCRIPT="$(mktemp)"
cat > "${FLAG_CHECK_SCRIPT}" <<'PY'
import base64
import gzip
import json
import sys
from urllib.parse import unquote_to_bytes

needle = b"cluster-version-manifest-path"
ign_path = sys.argv[1]

with open(ign_path, "r", encoding="utf-8") as fh:
    ign = json.load(fh)

found_paths = []
for entry in ign.get("storage", {}).get("files", []):
    path = entry.get("path", "")
    contents = entry.get("contents") or {}
    source = contents.get("source") or ""
    compression = contents.get("compression")
    data = b""

    if source.startswith("data:"):
        # data:[<mediatype>][;base64],<data>
        try:
            meta, payload = source.split(",", 1)
        except ValueError:
            continue
        if ";base64" in meta:
            data = base64.b64decode(payload)
        else:
            data = unquote_to_bytes(payload)
    elif not source:
        continue
    else:
        # Non-data URI (http/s3); skip — platform-external embeds inline
        continue

    if compression == "gzip":
        data = gzip.decompress(data)

    if needle in data:
        found_paths.append(path)

if found_paths:
    print("PRESENT")
    for p in found_paths:
        print(p)
    sys.exit(0)

print("ABSENT")
sys.exit(0)
PY

FLAG_STATUS="$(python3 "${FLAG_CHECK_SCRIPT}" "${BOOTSTRAP_IGN}" | head -n1)"
echo "bootstrap.ign cluster-version-manifest-path: ${FLAG_STATUS}"

RELEASE_VERSION="$(oc adm release info -a "${PULL_SECRET}" "${RELEASE_IMAGE}" -o=jsonpath='{.metadata.version}')"
echo "install release version: ${RELEASE_VERSION}"

if [[ "${FLAG_STATUS}" != "PRESENT" ]]; then
  echo "Preflight OK: bootstrap does not embed --cluster-version-manifest-path"
  exit 0
fi

echo "Bootstrap embeds --cluster-version-manifest-path; verifying install release CVO accepts it"

CVO_IMAGE="$(oc adm release info -a "${PULL_SECRET}" "${RELEASE_IMAGE}" --image-for=cluster-version-operator)"
echo "cluster-version-operator image: ${CVO_IMAGE}"

CVO_DIR="$(mktemp -d)"
# CVO image entrypoint binary path historically /usr/bin/cluster-version-operator
if ! env "NO_PROXY=*" "no_proxy=*" oc image extract "${CVO_IMAGE}" \
  --path="/usr/bin/cluster-version-operator:${CVO_DIR}" \
  -a "${PULL_SECRET}"; then
  echo "ERROR: failed to extract cluster-version-operator binary from ${CVO_IMAGE}"
  exit 1
fi

CVO_BIN="${CVO_DIR}/cluster-version-operator"
if [[ ! -x "${CVO_BIN}" ]]; then
  # oc image extract may drop the basename without execute bit in some versions
  if [[ -f "${CVO_BIN}" ]]; then
    chmod +x "${CVO_BIN}"
  else
    echo "ERROR: extracted CVO binary not found at ${CVO_BIN}"
    ls -la "${CVO_DIR}" || true
    exit 1
  fi
fi

HELP_OUT="$(mktemp)"
if ! "${CVO_BIN}" render --help >"${HELP_OUT}" 2>&1; then
  # Older binaries may use different help routing; fall back to bare help
  "${CVO_BIN}" --help >"${HELP_OUT}" 2>&1 || true
fi

if grep -q -- '--cluster-version-manifest-path' "${HELP_OUT}"; then
  echo "Preflight OK: CVO ${RELEASE_VERSION} accepts --cluster-version-manifest-path"
  exit 0
fi

cat <<EOF
ERROR: bootstrap/installer embeds --cluster-version-manifest-path but install release
CVO (${RELEASE_VERSION}) does not accept that flag.

This is an installer/bootstrap vs initial-release pairing bug. Ensure
platform-external-pre-conf-manifests extracts openshift-install from the install
payload (OPENSHIFT_INSTALL_RELEASE_IMAGE_OVERRIDE), not a newer installer imagestream.

Refusing to provision AWS resources.
EOF
echo "---- CVO help (excerpt) ----"
head -n 80 "${HELP_OUT}" || true
exit 1
