#!/bin/bash

# Do not enable tracing; step logs must not expose secrets.
set -euo pipefail

sleep "${SLEEP_DURATION}" &
wait "$!"
