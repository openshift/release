#!/bin/bash

set -o nounset
set -o errexit
set -o pipefail

if [[ -z "${CONFIGS}" ]]
then
    echo "CONFIGS is undefined. Set it and try again."
    exit 1
fi

if [[ -z "${SECRET_LOCATIONS}" ]]
then
    echo "SECRET_LOCATIONS is undefined. Set it and try again."
    exit 1
fi

TEST_PARAMETERS="--configs ${CONFIGS} \
--secret-locations ${SECRET_LOCATIONS} \
--provision-only"

if [[ -n ${SKIP_MUST_GATHER} ]]
then
  TEST_PARAMETERS="${TEST_PARAMETERS} --skip-must-gather"
fi

if [[ -n ${SKIP_DESTROY_CLUSTER} ]]
then
  TEST_PARAMETERS="${TEST_PARAMETERS} --skip-destroy-cluster"
fi

export REPORT_DIR="${ARTIFACT_DIR}"

/osde2e test ${TEST_PARAMETERS}