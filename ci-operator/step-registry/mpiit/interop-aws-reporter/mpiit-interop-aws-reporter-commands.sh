#!/bin/bash
set -o nounset
set -o errexit
set -o pipefail
set -o verbose

sleep 2h
RUN_COMMAND="poetry run swach --help"

echo "$RUN_COMMAND" | sed -r "s/token [=A-Za-z0-9\.\-]+/token hashed-token /g"

${RUN_COMMAND}