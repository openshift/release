#!/bin/bash

set -o nounset
set -o errexit
set -o pipefail


curl https://raw.githubusercontent.com/jupierce/ci-infra-dns-monitor/main/resources.yaml -o "${SHARED_DIR}/manifests.yml"

echo "Network tester manifests created"

