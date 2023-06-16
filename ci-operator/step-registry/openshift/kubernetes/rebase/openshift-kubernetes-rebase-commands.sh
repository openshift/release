#!/bin/bash

set -o nounset
set -o errexit
set -o pipefail

git clone --single-branch https://github.com/bertinatto/ocp-next.git /tmp/ocp-next
pushd /tmp/ocp-next || exit 1
sh do.sh ocp-next
