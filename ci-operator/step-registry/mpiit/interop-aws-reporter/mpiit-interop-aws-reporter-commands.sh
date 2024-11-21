#!/bin/bash
set -o nounset
set -o errexit
set -o pipefail

sleep 2h
RUN_COMMAND="poetry run swach --help"
