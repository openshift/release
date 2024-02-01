#!/usr/bin/env bash

set -o errexit
set -o nounset
set -o pipefail

pwd
ls -l
yamllint version
# yamllint -c "$CONFIG_FILE"