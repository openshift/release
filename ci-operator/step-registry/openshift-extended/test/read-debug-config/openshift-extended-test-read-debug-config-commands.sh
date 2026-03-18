#!/bin/bash
set -euo pipefail

echo "=========================================="
echo "  Debug Cluster Configuration"
echo "=========================================="

CONFIG_FILE=".debug-cluster-config"

if [[ -f "${CONFIG_FILE}" ]]; then
    echo "✓ Found configuration file"
    cat "${CONFIG_FILE}"
    echo ""

    # Source and export
    set -a
    source "${CONFIG_FILE}"
    set +a

    # Apply RELEASE_IMAGE
    if [[ -n "${RELEASE_IMAGE:-}" ]]; then
        export CUSTOM_OPENSHIFT_INSTALL_RELEASE_IMAGE_OVERRIDE="${RELEASE_IMAGE}"
        echo "✓ Using custom image: ${RELEASE_IMAGE}"
    fi

    # Apply FEATURE_SET if present
    [[ -n "${FEATURE_SET:-}" ]] && echo "✓ Feature set: ${FEATURE_SET}"
else
    echo "ℹ Using default: latest 4.22 nightly"
    echo ""
    echo "To customize, create .debug-cluster-config:"
    echo "  RELEASE_IMAGE=registry.ci.openshift.org/ocp/release:4.22.0-0.nightly-YYYY-MM-DD-HHMMSS"
fi

echo "=========================================="
