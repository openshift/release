#!/bin/bash

set -o nounset
set -o errexit
set -o pipefail

env

dir=/tmp/shared

echo "Copying nss artifacts from ${dir}"
ls -ll ${dir}




