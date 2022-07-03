#!/bin/bash

set -o nounset
set -o errexit
set -o pipefail

echo "Environment:"
printenv

echo "./scripts/rebase.sh to ${TARGET_RELEASE_IMAGE}"
./scripts/rebase.sh to "${TARGET_RELEASE_IMAGE}"
