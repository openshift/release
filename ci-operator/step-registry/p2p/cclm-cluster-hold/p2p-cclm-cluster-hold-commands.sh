#!/bin/bash
#
# Keep the hub and spokes up long enough to create a Windows VM from a workstation.
#
set -euo pipefail
shopt -s inherit_errexit

[[ -n "${HOLD_DURATION}" ]]
printf 'Holding the hub and spoke clusters for %s\n' "${HOLD_DURATION}" >&2
sleep "${HOLD_DURATION}"
