#!/bin/bash

set -o nounset
set -o errexit
set -o pipefail

# Use timeout from environment variable, default to 3 hours (10800 seconds)
DEBUG_WAIT_TIMEOUT="${DEBUG_WAIT_TIMEOUT:-10800}"

echo "Debug wait: sleeping for ${DEBUG_WAIT_TIMEOUT} seconds for debugging..."
sleep "${DEBUG_WAIT_TIMEOUT}"
echo "Debug wait complete." 