#!/bin/bash

set -o nounset
set -o errexit
set -o pipefail

echo "Copy logs and xunit to artifacts dir"
./copy_logs.sh "${ARTIFACT_DIR}"
