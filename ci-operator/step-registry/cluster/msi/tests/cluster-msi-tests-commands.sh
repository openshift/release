#!/bin/bash

set -o nounset
set -o errexit
set -o pipefail
set -o verbose

RUN_COMMAND="poetry run pytest tests -o log_cli=true --junit-xml='${ARTIFACT_DIR}/xunit_results.xml'  --pytest-log-file='${ARTIFACT_DIR}/pytest-tests.log' -m ${TEST_MARKER}"

for kubeconfig_value in $(env | grep -E '^KUBECONFIG[0-9]+_PATH' | sort  --version-sort); do
    kubeconfig_value=$(echo "kubeconfig_value" | sed -E  's/^KUBECONFIG[0-9]+_PATH=//')
    if  [ "${kubeconfig_value}" ]; then
      RUN_COMMAND+=" --kubeconfig-file-path ${kubeconfig_value} "
    fi
done

echo "$RUN_COMMAND"

${RUN_COMMAND}
