#!/bin/bash

set -o nounset
set -o errexit
set -o pipefail

ls -larth
git clone https://github.com/devfile/registry.git -b main

/bin/bash tests/check_rhtap_nightly.sh
