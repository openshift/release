#!/bin/bash

set -o nounset
set -o errexit
set -o pipefail

echo "************ baremetalds assisted conf devscripts extraworkers command ************"

echo "export NUM_EXTRA_WORKERS=${NUM_EXTRA_WORKERS}" | tee -a "${SHARED_DIR}/dev-scripts-additional-config"