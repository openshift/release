#!/usr/bin/bash
# Build resource-agents RPM on CentOS Stream 9 and 10 and tag in local registry.
# No push. Run from the release repo root or hack/tnf-resource-agents-build/.
set -euo pipefail
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
cd "${SCRIPT_DIR}"
echo "Building Stream 9 image..."
podman build -f Dockerfile.stream9 -t localhost/tnf-resource-agents-build:stream9 .
echo "Building Stream 10 image..."
podman build -f Dockerfile.stream10 -t localhost/tnf-resource-agents-build:stream10 .
echo "Done. Images in local store:"
podman images localhost/tnf-resource-agents-build --format "{{.Repository}}:{{.Tag}} {{.ID}}"
