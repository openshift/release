#!/bin/bash

set -o errexit
set -o nounset
set -o pipefail
set -o xtrace
set -x
ls

echo "START" >> ${SHARED_DIR}/krkn_start.txt

cat ${SHARED_DIR}/krkn_start.txt
