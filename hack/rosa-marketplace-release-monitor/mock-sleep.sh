#!/bin/bash

set -euo pipefail

printf '%s\n' "$1" >> "${TEST_SLEEP_ARGS_FILE:?}"
