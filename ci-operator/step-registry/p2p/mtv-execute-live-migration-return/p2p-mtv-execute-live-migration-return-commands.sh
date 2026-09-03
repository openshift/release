#!/bin/bash
#
# Thin wrapper for the return migration leg (spoke-2 → spoke-1).
#
# Sets MTV_MIGRATION_SUFFIX="-return" and MTV_CLEANUP_DEST_BEFORE_MIGRATION="true"
# so the shared execute script applies a "-return" suffix to all artifact names
# (status file, diag dir, JUnit XML, suite/classname) and cleans up stale
# VM/DV/PVC resources on the destination (spoke-1) before Plan creation.
#
# All migration logic lives in p2p-mtv-execute-live-migration-commands.sh, which is
# the single source of truth for CCLM spoke-to-spoke migration.
# The ref.yaml for this step sets the return-leg defaults (reversed spoke indices,
# -return Plan/Migration/Map names) so this script needs no hard-coded overrides.
#
set -euo pipefail
export MTV_MIGRATION_SUFFIX="${MTV_MIGRATION_SUFFIX:--return}"
export MTV_CLEANUP_DEST_BEFORE_MIGRATION="${MTV_CLEANUP_DEST_BEFORE_MIGRATION:-true}"
# CI mounts all step-registry commands scripts into the same flat directory.
# Use ${BASH_SOURCE[0]:-$0} so the expression is safe under set -u even when
# the BASH_SOURCE array is empty (can happen with some CI invocation methods).
# shellcheck source=../mtv-execute-live-migration/p2p-mtv-execute-live-migration-commands.sh
source "$(dirname "$(realpath "${BASH_SOURCE[0]:-$0}")")/p2p-mtv-execute-live-migration-commands.sh"
