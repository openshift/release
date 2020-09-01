#!/bin/bash

set -o nounset
set -o errexit
set -o pipefail

echo "************ baremetalds assisted conf service command ************"

echo "export SERVICE=${SERVICE}" >> "${SHARED_DIR}/assisted-additional-config"
