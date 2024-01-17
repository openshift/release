#!/bin/bash

set -o nounset
set -o errexit
set -o pipefail

cd "$(mktemp -d)"
git clone --branch send-webhook https://github.com/tnevrlka/qe-tools .
make build
./qe-tools prowjob create-report --report-portal-format
./qe-tools webhook report-portal
