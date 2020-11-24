#!/bin/bash

set -o nounset
set -o errexit
set -o pipefail

make test-e2e
