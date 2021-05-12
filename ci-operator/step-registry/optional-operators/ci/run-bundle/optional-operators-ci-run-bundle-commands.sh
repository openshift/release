#!/bin/bash

set -o nounset
set -o errexit
set -o pipefail

echo "Deploying an operator in the bundle format using operator-sdk run bundle command"

echo "$OO_BUNDLE_IMG"
cd /tmp
operator-sdk run bundle "$OO_BUNDLE_IMG"
