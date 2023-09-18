#!/bin/bash

set -o nounset
set -o errexit
set -o pipefail
set -o verbose

if [[ -n $CLUSTER_KUBECONFIG_PATH ]]; then
  # Extract clusters archive from SHARED_DIR
  tar -xzvf "${SHARED_DIR}/clusters_data.tar.gz" --one-top-leve=/tmp/clusters-data
  export KUBECONFIG=${CLUSTER_KUBECONFIG_PATH}
else
  export KUBECONFIG=${SHARED_DIR}/kubeconfig
fi

RUN_COMMAND="poetry run python app/cli.py operators --kubeconfig ${KUBECONFIG} "

OPERATORS_CMD=""
for operator_value in $(env | grep -E '^OPERATOR[0-9]+_CONFIG' | sort  --version-sort); do
    operator_value=$(echo "$operator_value" | sed -E  's/^OPERATOR[0-9]+_CONFIG=//')
    if  [ "${operator_value}" ]; then
      OPERATORS_CMD+=" --operator ${operator_value} "
    fi
done

RUN_COMMAND="${RUN_COMMAND} ${OPERATORS_CMD}"

if [ "${ADDONS_OPERATORS_RUN_IN_PARALLEL}" = "true" ]; then
    RUN_COMMAND+=" --parallel"
fi

RUN_COMMAND+=" uninstall"

echo "$RUN_COMMAND" | sed -r "s/token [=A-Za-z0-9\.\-]+/token hashed-token /g"

${RUN_COMMAND}
