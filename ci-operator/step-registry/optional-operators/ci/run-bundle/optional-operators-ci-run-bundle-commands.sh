#!/bin/bash

set -o nounset
set -o errexit
set -o pipefail

echo "Deploying an operator in the bundle format using operator-sdk run bundle command"

cd /tmp
operator-sdk run bundle "${OO_BUNDLE_IMG}" \
                        --index-image "${OO_INDEX_IMG}" \
                        --namespace "${OO_INSTALL_NAMESPACE}" \
                        --install-mode "${OO_TARGET_NAMESPACES}"
