#!/bin/bash

set -o nounset
set -o errexit
set -o pipefail
set -o verbose

export KUBECONFIG=${SHARED_DIR}/kubeconfig

RUN_COMMAND="
    --kubeconfig ${KUBECONFIG} \
    --timeout ${TIMEOUT} \
    "

OPERATORS_CMD=""
for i in {1..4}; do
  OPERATOR_VALUE=$(eval "echo $"OPERATOR$i"_CONFIG")
  if [[ -n $OPERATOR_VALUE ]]; then
    OPERATORS_CMD="${OPERATORS_CMD} --operators ${OPERATOR_VALUE}"
  fi
done

echo "$OPERATORS_CMD"

RUN_COMMAND="${RUN_COMMAND} ${OPERATORS_CMD}"


if [ -n "${PARALLEL}" ]; then
    RUN_COMMAND="${RUN_COMMAND} --parallel"
fi

echo "$RUN_COMMAND"

poetry run python app/cli.py operator \
    ${RUN_COMMAND} \
    install
