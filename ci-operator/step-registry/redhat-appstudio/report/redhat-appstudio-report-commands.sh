#!/bin/bash

set -o nounset
set -o errexit
set -o pipefail

cd "$(mktemp -d)"
git clone --branch main https://github.com/redhat-appstudio/qe-tools .
make build
./qe-tools prowjob create-report