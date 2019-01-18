#!/bin/sh

# This script runs /tools/populate-owners

REPO_ROOT="$(git rev-parse --show-toplevel)" &&
exec go run "${REPO_ROOT}/tools/populate-owners/main.go" $1
