#!/usr/bin/env bash

set -euo pipefail

if [ "$#" -ne 3 ]; then
  echo "require exactly 3 args"
  exit 1
fi


sed_cmd="${sed_cmd:-sed}"

DASHBOARD_NAME=$1
readonly DASHBOARD_NAME
IMPORT_STRING_PATH=$2
readonly IMPORT_STRING_PATH
OUTPUT_FILE=$3
readonly OUTPUT_FILE

SCRIPT_DIR=$( cd -- "$( dirname -- "${BASH_SOURCE[0]}" )" &> /dev/null && pwd )

${sed_cmd} "s/{{DASHBOARD_NAME}}/${DASHBOARD_NAME}/g;s/{{IMPORT_STRING_PATH}}/${IMPORT_STRING_PATH}/g" ${SCRIPT_DIR}/grafanadashboard.template > ${OUTPUT_FILE}
