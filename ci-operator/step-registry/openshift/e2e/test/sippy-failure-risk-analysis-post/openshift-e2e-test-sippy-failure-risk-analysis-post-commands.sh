#!/bin/bash

set -o nounset
set -o errexit
set -o pipefail

echo "All artifacts in $ARTIFACT_DIR"

ls -R

which curl
which jq
