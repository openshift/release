#!/bin/bash

set -o nounset
set -o errexit
set -o pipefail

/bin/bash tests/check_rhtap_nightly.sh
