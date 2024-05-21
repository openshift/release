#!/bin/bash

set -o nounset
set -o errexit
set -o pipefail

function cleanup() {
  for child in $( jobs -p ); do
    kill "${child}"
  done
  wait
}
trap cleanup EXIT

make ci-test-e2e-azure