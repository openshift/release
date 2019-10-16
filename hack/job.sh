#!/bin/bash
# Create a new run of the Prow job
set -euo pipefail
BASE="$( dirname "${BASH_SOURCE[0]}" )"
source "$BASE/images.sh"

docker run \
    --rm \
    --volume "$PWD:/tmp/release:z" \
    --workdir /tmp/release \
    "$MKPJ_IMG" \
    --config-path core-services/prow/02_config/_config.yaml \
    --job-config-path ci-operator/jobs/ \
    --job "${1}" |
    oc apply -f -
