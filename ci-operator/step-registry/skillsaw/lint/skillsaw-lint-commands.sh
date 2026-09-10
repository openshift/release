#!/bin/bash
set -o errexit
set -o nounset
set -o pipefail

skillsaw lint --no-custom-rules . --output "${ARTIFACT_DIR}/skillsaw-summary.html"
