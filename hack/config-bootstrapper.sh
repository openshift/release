#!/bin/bash
set -euo pipefail

dir=$(realpath "$(dirname "${BASH_SOURCE}")/..")
config-bootstrapper \
    --dry-run=false \
    --source-path "${dir}" \
    --config-path "${dir}/cluster/ci/config/prow/config.yaml" \
    --plugin-config "${dir}/cluster/ci/config/prow/plugins.yaml"
