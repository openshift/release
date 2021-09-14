#!/usr/bin/env bash

set -Eeuo pipefail

export OS_CLOUD
export OS_CLIENT_CONFIG_FILE="${SHARED_DIR}/clouds.yaml"

./clean-ci-resources.sh -o "${ARTIFACT_DIR}/result.json" --delete-everything-older-than-5-hours
