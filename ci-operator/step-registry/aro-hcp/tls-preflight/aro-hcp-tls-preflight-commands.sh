#!/bin/bash
set -o errexit
set -o nounset
set -o pipefail

exec hack/ci/tls-preflight.sh
