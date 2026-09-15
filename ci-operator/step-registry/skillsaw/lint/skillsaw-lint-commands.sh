#!/bin/bash
set -o errexit
set -o nounset
set -o pipefail

skillsaw lint . --output "${ARTIFACT_DIR}/skillsaw-summary.html"
