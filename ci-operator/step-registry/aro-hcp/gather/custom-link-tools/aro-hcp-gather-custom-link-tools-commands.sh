#!/bin/bash
set -o errexit
set -o nounset
set -o pipefail
set -o xtrace 

test/aro-hcp-tests custom-link-tools --timing-input ${SHARED_DIR} --output ${ARTIFACT_DIR}/