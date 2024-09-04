#!/bin/bash

set -o errexit
set -o nounset
set -o pipefail
set -o xtrace
set -x

oc new-project start-kraken