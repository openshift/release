#!/bin/bash

set -o nounset
set -o errexit
set -o pipefail

okd-camgi --output "${ARTIFACT_DIR}/investigator.html" "${SHARED_DIR}/must-gather.tar.gz"
