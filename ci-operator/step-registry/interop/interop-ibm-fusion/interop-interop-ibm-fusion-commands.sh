#!/bin/bash
set -euxo pipefail
shopt -s inherit_errexit 2>/dev/null || true

interop-tests run-suite interop/ibm-fusion
true
