#!/bin/bash
# Create a new run of the Prow job
set -euo pipefail
BASE="$( dirname "${BASH_SOURCE[0]}" )"
source "$BASE/images.sh"

if [[ -n "${GITHUB_TOKEN_PATH:-}" ]]; then
	volume="--volume $( dirname "${GITHUB_TOKEN_PATH}" ):/secrets:z"
	arg="--github-token-path /secrets/$( basename "${GITHUB_TOKEN_PATH}" )"
fi

CONTAINER_ENGINE=${CONTAINER_ENGINE:-docker}
CONTAINER_ENGINE_OPTS=${CONTAINER_ENGINE_OPTS:- --platform linux/amd64}
if [ -z ${VOLUME_MOUNT_FLAGS+x} ]; then VOLUME_MOUNT_FLAGS=':z'; else echo "VOLUME_MOUNT_FLAGS is set to '$VOLUME_MOUNT_FLAGS'"; fi


STATE=${STATE:-triggered}
CLUSTER=${CLUSTER:-}

$CONTAINER_ENGINE run $CONTAINER_ENGINE_OPTS \
    --rm \
    --volume "$PWD:/tmp/release${VOLUME_MOUNT_FLAGS}" \
    ${volume:-} \
    --workdir /tmp/release \
    "$MKPJ_IMG" \
    --config-path core-services/prow/02_config/_config.yaml \
    --job-config-path ci-operator/jobs/ \
    ${BASE_REF:+"--base-ref" "${BASE_REF}"} \
    ${PULL_NUMBER:+"--pull-number" "${PULL_NUMBER}"} \
    ${arg:-} \
    --job "${1}" |
    {
        if [[ -n "$CLUSTER" ]]; then
            yq e ".spec.cluster = \"$CLUSTER\" | .status.state = \"$STATE\"" -
        else
            cat -
        fi
    } | 
    oc --context app.ci --namespace ci --as system:admin apply -f -
