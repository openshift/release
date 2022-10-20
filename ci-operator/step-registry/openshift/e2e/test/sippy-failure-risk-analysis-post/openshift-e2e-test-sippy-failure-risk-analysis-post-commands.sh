#!/bin/bash

set -o nounset
set -o errexit
set -o pipefail

echo "All artifacts in $ARTIFACT_DIR"

ls -R $ARTIFACT_DIR

which curl
which jq
