#!/bin/bash

set -o nounset
set -o errexit
set -o pipefail

echo "************ baremetalds devscripts conf compact command ************"

echo "export NUM_WORKERS=0" >> "${SHARED_DIR}/dev-scripts-additional-config"
