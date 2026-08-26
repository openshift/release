#!/bin/bash
#
# Thin directional wrapper for p2p-mtv-execute-hub-spoke-migration.
#
# Hardcodes P2P_MIGRATION_DIRECTION=spoke-to-hub so this step can appear AFTER spoke upgrade
# steps in a chain independently of any prior hub→spoke migration step.
#
# All migration logic lives in p2p-mtv-execute-hub-spoke-migration-commands.sh, which is the
# single source of truth for CCLM hub↔spoke migration.
#
# Use this step in upgrade chains:
#   hub→spoke migration → upgrade spoke → health checks → this step (spoke→hub)
#
# The p2p-mtv-spoke-to-hub-migration-ref.yaml declares P2P_MIGRATION_DIRECTION default
# "spoke-to-hub" so the execute script picks up the direction even if the source call below
# ever fails to resolve (e.g. flat-directory CI mount). In that case, update the ref.yaml
# commands: field to the relative path resolved by the CI runner.
#
set -euo pipefail
export P2P_MIGRATION_DIRECTION="spoke-to-hub"
# The CI operator step-registry preserves the directory hierarchy when mounting scripts into
# the step container. The execute script therefore resolves via the relative path below.
# shellcheck source=../mtv-execute-hub-spoke-migration/p2p-mtv-execute-hub-spoke-migration-commands.sh
source "$(dirname "$(realpath "${BASH_SOURCE[0]}")")/../mtv-execute-hub-spoke-migration/p2p-mtv-execute-hub-spoke-migration-commands.sh"
