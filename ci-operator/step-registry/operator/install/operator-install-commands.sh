#!/bin/bash

set -o nounset
set -o errexit
set -o pipefail
set -o verbose

export KUBECONFIG=${SHARED_DIR}/kubeconfig

RUN_COMMAND="poetry run python app/cli.py operators --kubeconfig ${KUBECONFIG} --timeout ${TIMEOUT} "

OPERATORS_CMD=""
for i in {1..6}; do
  OPERATOR_VALUE=$(eval "echo $"OPERATOR$i"_CONFIG")
  if [[ -n $OPERATOR_VALUE ]]; then
    OPERATORS_CMD+=" --operator ${OPERATOR_VALUE} "
  fi
done

RUN_COMMAND="${RUN_COMMAND} ${OPERATORS_CMD}"

if [ -n "${PARALLEL}" ]; then
    RUN_COMMAND+=" --parallel"
fi

RUN_COMMAND+=" install"

echo "$RUN_COMMAND" | sed -r "s/token [=A-Za-z0-9\.\-]+/token hashed-token /g"

${RUN_COMMAND}
