#!/bin/bash
set -o errexit
set -o nounset
set -o pipefail

/tmp/yq -i '.platform.aws.lbType="NLB"' ${SHARED_DIR}/install-config.yaml

echo "the platform of install-config.yaml"
echo "-------------------"
/tmp/yq '.platform' < ${SHARED_DIR}/install-config.yaml
