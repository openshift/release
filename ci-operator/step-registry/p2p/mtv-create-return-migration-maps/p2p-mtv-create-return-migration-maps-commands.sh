#!/bin/bash
#
# Thin wrapper for the return-leg map creation (spoke-2 → spoke-1).
#
# All map creation logic lives in p2p-mtv-create-migration-maps-commands.sh.
# The ref.yaml for this step sets the return-leg defaults:
#   - MTV_SOURCE_PROVIDER=spoke-2, MTV_DESTINATION_PROVIDER=spoke-1
#   - MTV_NETWORK_MAP_NAME=spoke-network-map-return
#   - MTV_STORAGE_MAP_NAME=spoke-storage-map-return
# so no hard-coded overrides are needed here.
#
# Both the forward and return map steps append to mtv-migration-maps-status.txt
# in ARTIFACT_DIR, giving a single artifact with the status of all four maps.
#
set -euo pipefail
# CI mounts all step-registry commands scripts into the same flat directory.
# Use ${BASH_SOURCE[0]:-$0} so the expression is safe under set -u even when
# the BASH_SOURCE array is empty (can happen with some CI invocation methods).
# shellcheck source=../mtv-create-migration-maps/p2p-mtv-create-migration-maps-commands.sh
source "$(dirname "$(realpath "${BASH_SOURCE[0]:-$0}")")/p2p-mtv-create-migration-maps-commands.sh"
