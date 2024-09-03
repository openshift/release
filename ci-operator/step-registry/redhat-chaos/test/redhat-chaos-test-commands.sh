#!/bin/bash

set -o errexit
set -o nounset
set -o pipefail
set -o xtrace
set -x

python3 --version

python3 -m pip list
