#!/bin/bash

set -o nounset
set -o errexit
set -o pipefail
set -o verbose

unset GOFLAGS

ls -alh /var/run/integration-tokens

export TEST_OFFLINE_TOKEN; TEST_OFFLINE_TOKEN=$(cat /var/run/integration-tokens/TEST_OFFLINE_TOKEN)
export TEST_REGISTRATION_OFFLINE_TOKEN; TEST_REGISTRATION_OFFLINE_TOKEN=$(cat /var/run/integration-tokens/TEST_REGISTRATION_OFFLINE_TOKEN)
export TEST_SREP_OFFLINE_TOKEN; TEST_SREP_OFFLINE_TOKEN=$(cat /var/run/integration-tokens/TEST_SREP_OFFLINE_TOKEN)
export TEST_SUPPORT_OFFLINE_TOKEN; TEST_SUPPORT_OFFLINE_TOKEN=$(cat /var/run/integration-tokens/TEST_SUPPORT_OFFLINE_TOKEN)
export TEST_OFFLINE_TOKEN; TEST_OFFLINE_TOKEN=$(cat /var/run/integration-tokens/TEST_OFFLINE_TOKEN)

./run_integration_tests.sh
