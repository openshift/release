#!/bin/bash
# Create a pod from a Prow job using the test-infra mkpj and mkpod utilities.
# The required information about the pull request can be passed in a few
# different ways:
#
# 1. Passing the pull request number as the only argument.  `mkpj`'s defaulting
# behavior will use Github's API to fetch the required information.
# Convenient, but has been victim of API throttling in the past.
# 2. Passing the required information as environment variables.  See the
# `pj_env.py` script for a way to set them using `git`.  The variables are:
#
# - BASE_REF
# - BASE_SHA
# - PULL_NUMBER
# - PULL_SHA
# - PULL_AUTHOR
set -euo pipefail

run() {
    docker run \
        --rm \
        --volume "$PWD:/tmp/release:z" \
        --workdir /tmp/release \
        "$MKPJ_IMG" \
        --config-path core-services/prow/02_config/_config.yaml \
        --job-config-path ci-operator/jobs/ \
        "$@" \
        | docker run --interactive "$MKPOD_IMG" --prow-job -
}

BASE="$( dirname "${BASH_SOURCE[0]}" )"
source "$BASE/images.sh"

case "$#" in
1) run --job "$1" \
    --base-ref "$BASE_REF" --base-sha "$BASE_SHA" \
    --pull-number "$PULL_NUMBER" --pull-sha "$PULL_SHA" \
    --pull-author "$PULL_AUTHOR";;
2) run --job "$1" --pull-number "$2";;
*) echo >&2 "Usage: $0 job_name [pull_number]"; exit 1;;
esac
