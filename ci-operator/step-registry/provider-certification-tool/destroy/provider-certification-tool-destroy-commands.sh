#!/bin/bash

set -o nounset
set -o errexit
set -o pipefail

export KUBECONFIG=${SHARED_DIR}/kubeconfig

source "${SHARED_DIR}/install-env"

echo "Downloading OPCT binary from $BIN_URL"
curl -o "${OPCT_EXEC}" -LJO "${BIN_URL}"
chmod u+x "${OPCT_EXEC}"
test -x "${OPCT_EXEC}" && echo "OPCT binary ${OPCT_EXEC} found and ready to be used on the version $LATEST_VERSION"


# Run destroy command
${OPCT_EXEC} destroy