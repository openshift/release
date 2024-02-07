#!/usr/bin/env bash

set -o errexit
set -o nounset
set -o pipefail

pwd
ls -l
ls -l /
find . -type f -name "*.sh" -print0 | xargs -r -0 shellcheck
