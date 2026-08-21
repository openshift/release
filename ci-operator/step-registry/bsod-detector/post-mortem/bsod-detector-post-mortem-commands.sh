#!/bin/bash

set -eux -o pipefail

export BSOD_MODE=post-mortem
exec /opt/bsod-detector/ci/entrypoint.sh
