#!/bin/bash

set -o nounset
set -o errexit
set -o pipefail
set -o verbose

sleep 2h

cd odh-dashboard && npm install && npm run build

CY_RESULTS_DIR="test-output" \
  npm --verbose run \
  --prefix frontend cypress:run -- \
  --env "skipTags='@Bug @Maintain'" \
  --config video=true
