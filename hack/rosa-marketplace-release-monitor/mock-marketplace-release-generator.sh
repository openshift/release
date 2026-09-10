#!/bin/bash

set -euo pipefail

printf '%s\n' "$@" > "${TEST_GENERATOR_ARGS_FILE}"
exit "${TEST_GENERATOR_EXIT_CODE:-0}"
