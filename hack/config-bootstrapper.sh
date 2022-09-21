#!/bin/sh
# Note: this is also executed in the `config-bootstrapper` upstream image, which
# only has `busybox`'s `ash` shell.  This is why this script is more
# inconveniently written than expected.
set -euo pipefail

trap 'rm -f VERSION' EXIT

if [[ "${CI:-}" ]]; then
    dir=$PWD
    bin=/ko-app/config-bootstrapper
else
    dir=$(realpath "$(dirname "${BASH_SOURCE}")/..")
    bin=config-bootstrapper
fi
config_dir=${dir}/core-services/prow/02_config
printf %s "$(git rev-parse HEAD)" > VERSION
# `=` is necessary in `--dry-run=false` because Go is silly
"${bin}" \
    --dry-run=false \
    --source-path "${dir}" \
    --config-path "${config_dir}/_config.yaml" \
    --plugin-config "${config_dir}/_plugins.yaml" \
    --supplemental-plugin-config-dir "${config_dir}" \
    --supplemental-prow-config-dir "${config_dir}" \
    "$@"
