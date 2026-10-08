#!/usr/bin/env bash

set -x
set -o errexit
set -o nounset
set -o pipefail

MTU_MIGRATION_CONFIG="${SHARED_DIR}/mtu-migration-config"

[ -f "$MTU_MIGRATION_CONFIG" ] && rm -f "$MTU_MIGRATION_CONFIG"

echo "MTU_OFFSET=-${MTU_DECREASE}" > "$MTU_MIGRATION_CONFIG"
