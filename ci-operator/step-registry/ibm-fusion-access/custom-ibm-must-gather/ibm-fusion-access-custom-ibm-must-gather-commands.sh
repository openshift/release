#!/bin/bash
set -eux -o pipefail; shopt -s inherit_errexit

mustGatherTmpDir="/tmp/ibm-must-gather"
mkdir -p "${mustGatherTmpDir}"

oc adm must-gather --image="${FA__MUST_GATHER_IMAGE}" --dest-dir="${mustGatherTmpDir}"

tar -czf "${ARTIFACT_DIR}/ibm-must-gather.tar.gz" -C /tmp ibm-must-gather

true
