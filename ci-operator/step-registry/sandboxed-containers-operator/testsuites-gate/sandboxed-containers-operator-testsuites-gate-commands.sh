#!/bin/bash

set -euo pipefail

# Create the gate file the POST-phase testsuites read. The file is empty on
# purpose: its mere presence signals that the test phase was reached, which only
# happens when the pre (setup) phase succeeded.
GATE="${SHARED_DIR}/testsuites_gate"

echo "Creating testsuites gate file: ${GATE}"
touch "${GATE}"
