#!/bin/bash
set -o errexit
set -o nounset
set -o pipefail
set -x

# Test remove after determining which is the correct directory
# <----
echo "LS DIR ARTIFACT_DIR: ${ARTIFACT_DIR}"
ls -l $ARTIFACT_DIR

echo "LS DIR ARTIFACTS: ${ARTIFACTS}"
ls -l $ARTIFACTS
# ---->