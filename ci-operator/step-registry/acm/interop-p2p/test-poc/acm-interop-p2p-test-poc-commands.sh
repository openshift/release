#!/bin/bash

set -euxo pipefail; shopt -s inherit_errexit

# Sleep 17h (61200s) - step timeout is 18h, leaving 1h buffer for CI teardown
sleep 61200

true
