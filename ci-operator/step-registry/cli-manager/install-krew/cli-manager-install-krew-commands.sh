#!/bin/bash

set -o nounset
set -o errexit
set -o pipefail

echo "=== Installing Krew (kubectl plugin manager) ==="

# Detect OS and architecture
OS="$(uname | tr '[:upper:]' '[:lower:]')"
ARCH="$(uname -m | sed -e 's/x86_64/amd64/' -e 's/aarch64/arm64/' -e 's/armv7l/arm/')"
KREW="krew-${OS}_${ARCH}"

# Create temporary directory for Krew installation
KREW_TEMP_DIR=$(mktemp -d)
trap 'rm -rf ${KREW_TEMP_DIR}' EXIT

echo "Downloading Krew ${KREW}..."
curl -fsSL "https://github.com/kubernetes-sigs/krew/releases/latest/download/${KREW}.tar.gz" \
  -o "${KREW_TEMP_DIR}/${KREW}.tar.gz"

echo "Extracting Krew..."
tar -xzf "${KREW_TEMP_DIR}/${KREW}.tar.gz" -C "${KREW_TEMP_DIR}"

echo "Installing Krew..."
"${KREW_TEMP_DIR}/${KREW}" install krew

# Verify installation and show version
echo "Krew installed successfully:"
"${KREW_ROOT:-$HOME/.krew}/bin/kubectl-krew" version

echo "=== Krew installation complete ==="
echo "To use Krew, ensure \${KREW_ROOT:-\$HOME/.krew}/bin is in your PATH"
