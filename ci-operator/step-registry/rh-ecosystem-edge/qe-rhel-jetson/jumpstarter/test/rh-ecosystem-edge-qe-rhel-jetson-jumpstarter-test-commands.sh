#!/bin/bash
set -euo pipefail

# Set up Jumpstarter client config from mounted secret
mkdir -p ~/.config/jumpstarter
cp /var/run/secrets/jumpstarter/config ~/.config/jumpstarter/client.yaml

# Load SSH credentials without leaking them into logs
[[ $- == *x* ]] && WAS_TRACING=true || WAS_TRACING=false
set +x

export JETSON_USERNAME
JETSON_USERNAME=$(cat /var/run/secrets/jetson-ssh/username)
export JETSON_PASSWORD
JETSON_PASSWORD=$(cat /var/run/secrets/jetson-ssh/password)

$WAS_TRACING && set -x

cd /opt/qe-rhel-jetson-jumpstarter
jmp shell --lease "${JUMPSTARTER_LEASE_NAME}" -- \
    python wrapper.py pytest "${TEST_SUITE}"
