#!/bin/bash

set -euo pipefail

if [[ "$*" == *"adm release info"* ]]; then
  [[ "${TEST_OC_INFO_EXIT_CODE:-0}" == "0" ]] || exit "${TEST_OC_INFO_EXIT_CODE}"
  sed -n '1,$p' "${TEST_RELEASE_INFO_FIXTURE:?}"
  exit 0
fi

printf 'unexpected mock oc arguments: %s\n' "$*" >&2
exit 64
