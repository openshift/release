#!/bin/bash

set -o nounset
set -o errexit
set -o pipefail

cd "$(mktemp -d)"
git clone https://github.com/psturc/ci-test-reporter-poc .
go mod vendor
go run main.go