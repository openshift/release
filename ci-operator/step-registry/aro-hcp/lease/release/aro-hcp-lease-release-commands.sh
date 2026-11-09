#!/bin/bash
set -o errexit
set -o nounset
set -o pipefail

./test/aro-hcp-tests slot-manager release --shared-dir "${SHARED_DIR}"
