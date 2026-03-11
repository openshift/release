#!/bin/bash

set -o nounset
set -o errexit
set -o pipefail

MUST_GATHER_DIR="${ARTIFACT_DIR}/must-gather"
mkdir -p "${MUST_GATHER_DIR}"

# Download the MCO sanitizer binary from mirror
curl -sL "https://mirror.openshift.com/pub/ci/$(arch)/mco-sanitize/mco-sanitize" > /tmp/mco-sanitize
chmod +x /tmp/mco-sanitize

oc --kubeconfig="${SHARED_DIR}/kubeconfig" adm must-gather --dest-dir="${MUST_GATHER_DIR}"

# Sanitize MCO resources to remove sensitive information.
# If the sanitizer fails, fall back to manual redaction.
if ! /tmp/mco-sanitize --input="${MUST_GATHER_DIR}"; then
  find "${MUST_GATHER_DIR}" -type f -path '*/cluster-scoped-resources/machineconfiguration.openshift.io/*' -exec sh -c 'echo "REDACTED" > "$1" && mv "$1" "$1.redacted"' _ {} \;
fi  

tar -czC "${MUST_GATHER_DIR}" -f "${ARTIFACT_DIR}/must-gather.tar.gz" .
rm -rf "${MUST_GATHER_DIR}"
