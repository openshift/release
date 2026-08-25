#!/bin/bash

set -o nounset
set -o errexit
set -o pipefail

export PATH=/usr/libexec/origin:$PATH

# Install TestExtensionAdmission CRD for out-of-payload test extensions
echo "Installing TestExtensionAdmission CRD..."
set +o errexit
if OPENSHIFT_SKIP_EXTERNAL_TESTS=1 openshift-tests extension-admission install-crd; then
    echo "TestExtensionAdmission CRD installed successfully"
else
    echo "Warning: Failed to install TestExtensionAdmission CRD (non-fatal)"
fi
set -o errexit
