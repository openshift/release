#!/usr/bin/env bash
set -euo pipefail

echo "=== Build gcphcpctl CLI ==="
echo ""

REPO="${GCPHCPCTL_REPO:-https://github.com/openshift-online/gcp-hcp-ctl.git}"
REF="${GCPHCPCTL_REF:-main}"

echo "  Repo: ${REPO}"
echo "  Ref:  ${REF}"
echo ""

cd /tmp

echo "Cloning repository..."
git clone "${REPO}" gcp-hcp-ctl
cd gcp-hcp-ctl
git checkout "${REF}"

echo "Syncing vendor directory..."
go mod vendor

echo "Building gcphcpctl..."
make build

cp bin/gcphcpctl "${SHARED_DIR}/gcphcpctl"
chmod +x "${SHARED_DIR}/gcphcpctl"

echo ""
echo "gcphcpctl built successfully"
"${SHARED_DIR}/gcphcpctl" version 2>/dev/null || echo "  (version command not available)"
echo "Binary written to SHARED_DIR/gcphcpctl"
