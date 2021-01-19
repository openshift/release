#!/bin/bash
# Create a new run of the Prow job
set -euo pipefail
BASE="$( dirname "${BASH_SOURCE[0]}" )"
source "$BASE/images.sh"

if [[ -n "${GITHUB_TOKEN_PATH:-}" ]]; then
	volume="--volume $( dirname "${GITHUB_TOKEN_PATH}" ):/secrets:z"
	arg="--github-token-path /secrets/$( basename "${GITHUB_TOKEN_PATH}" )"
fi
docker run \
    --rm \
    --volume "$PWD:/tmp/release:z" \
    ${volume:-} \
    --workdir /tmp/release \
    "$MKPJ_IMG" \
    --config-path core-services/prow/02_config/_config.yaml \
    --job-config-path ci-operator/jobs/ \
    ${BASE_REF:+"--base-ref" "${BASE_REF}"} \
    --pull-number 497 \
    ${arg:-} \
    --job "${1}" |
    oc --context app.ci --namespace ci --as system:admin apply -f -
