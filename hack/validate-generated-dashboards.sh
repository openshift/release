#!/bin/bash

set -o errexit
set -o nounset
set -o pipefail

current_dir="$( cd "$( dirname "${BASH_SOURCE[0]}" )" >/dev/null 2>&1 && pwd )"
echo "current_dir: ${current_dir}"
mixins_dir="$(readlink -f ${current_dir}/../cluster/ci/monitoring/mixins)"
echo "mixins_dir: ${mixins_dir}"

make -C "${mixins_dir}" validate-latest
