#!/bin/bash
set -o errexit
set -o nounset
set -o pipefail
make visualize TIMING_OUTPUT=${SHARED_DIR}/steps.yaml VISUALIZATION_OUTPUT=${ARTIFACT_DIR}/timing