#!/bin/bash

set -o nounset
set -o errexit
set -o pipefail

echo running on ${LEASED_RESOURCE}
env
echo running on ${RHOSO_LEASED_RESOURCE}
