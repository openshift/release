#!/bin/bash

set -o nounset
set -o errexit
set -o pipefail

echo "************ baremetalds assisted conf cvo command ************"

echo "export ADDITIONAL_PARAMS=-cvo" >> "${SHARED_DIR}/assisted-additional-config"
