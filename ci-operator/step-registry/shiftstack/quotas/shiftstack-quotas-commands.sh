#!/usr/bin/env bash

set -Eeuo pipefail

export OS_CLOUD
export OS_CLIENT_CONFIG_FILE="${SHARED_DIR}/clouds.yaml"
MIN_PERCENTAGE=${MIN_PERCENTAGE:-15}

./borderline.sh --min-percentage "${MIN_PERCENTAGE}"
