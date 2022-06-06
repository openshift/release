#!/usr/bin/env bash
set -eo pipefail

shared_env=$1

cat > "$shared_env" <<- "EOF"
    export GOPATH="${WORKSPACE_ROOT}/go"
    export STACKROX_ROOT="${GOPATH}/src/github.com/stackrox"
    export SOURCE_ROOT="${STACKROX_ROOT}/collector"
    export CI_ROOT="${SOURCE_ROOT}/.circleci"
    export COLLECTOR_SOURCE_ROOT="${SOURCE_ROOT}/collector"
    export PATH="${PATH}:${GOPATH}/bin:${WORKSPACE_ROOT}/bin"
    export MAX_LAYER_MB=300
EOF
