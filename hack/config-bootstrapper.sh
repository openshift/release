#!/bin/bash
set -euo pipefail

dir=$(realpath "$(dirname "${BASH_SOURCE}")/..")
config-bootstrapper \
    --dry-run=false \
    --source-path "${dir}" \
    --config-path "${dir}/core-services/prow/02_config/_config.yaml" \
    --plugin-config "${dir}/core-services/prow/02_config/_plugins.yaml"
