#!/bin/bash

set -o nounset
set -o errexit
set -o pipefail

# shellcheck source=/dev/null
source "${SHARED_DIR}/install-env"
extract_opct

# Run the tool in dedicated mode with watch flag set.
echo "Running OPCT with regular mode"
${OPCT_EXEC} run --watch
