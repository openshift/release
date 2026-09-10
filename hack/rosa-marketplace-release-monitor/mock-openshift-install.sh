#!/bin/bash

set -euo pipefail

[[ "$*" == "coreos print-stream-json" ]]
if [[ "${TEST_INSTALLER_EXIT_CODE:-0}" != "0" ]]; then
  exit "${TEST_INSTALLER_EXIT_CODE}"
fi
cat "${TEST_COREOS_FIXTURE}"
