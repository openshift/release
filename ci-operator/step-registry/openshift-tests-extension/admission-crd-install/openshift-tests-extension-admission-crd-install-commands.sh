#!/bin/bash

set -o nounset
set -o errexit
set -o pipefail

export PATH=/usr/libexec/origin:$PATH

# For disconnected or otherwise unreachable environments, we want to
# have steps use an HTTP(S) proxy to reach the API server. This proxy
# configuration file should export HTTP_PROXY, HTTPS_PROXY, and NO_PROXY
# environment variables, as well as their lowercase equivalents (note
# that libcurl doesn't recognize the uppercase variables).
if test -f "${SHARED_DIR}/proxy-conf.sh"
then
    # shellcheck disable=SC1090
    source "${SHARED_DIR}/proxy-conf.sh"
fi

# Install TestExtensionAdmission CRD for out-of-payload test extensions
echo "Installing TestExtensionAdmission CRD..."
set +o errexit
if OPENSHIFT_SKIP_EXTERNAL_TESTS=1 openshift-tests extension-admission install-crd; then
    echo "TestExtensionAdmission CRD installed successfully"
else
    echo "Warning: Failed to install TestExtensionAdmission CRD (non-fatal)"
fi
set -o errexit
