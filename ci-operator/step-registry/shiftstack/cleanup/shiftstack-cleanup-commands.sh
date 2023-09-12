#!/usr/bin/env bash

set -Eeuo pipefail

export OS_CLOUD
export OS_CLIENT_CONFIG_FILE="${SHARED_DIR}/clouds.yaml"

./clean-ci-resources.sh -o "${ARTIFACT_DIR}/result.json" --no-dry-run
