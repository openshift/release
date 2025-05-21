#!/bin/bash

set -o nounset
set -o errexit
set -o pipefail
set -o verbose

unset GOFLAGS

export OSD_ADMIN_ACCESS_KEY_ID; OSD_ADMIN_ACCESS_KEY_ID=$(cat /var/run/integration-tokens/OSD_ADMIN_ACCESS_KEY_ID)
export OSD_ADMIN_SECRET; OSD_ADMIN_SECRET=$(cat /var/run/integration-tokens/OSD_ADMIN_SECRET)
export SHARED_VPC_ACCESS_KEY_ID; SHARED_VPC_ACCESS_KEY_ID=$(cat /var/run/integration-tokens/SHARED_VPC_ACCESS_KEY_ID)
export SHARED_VPC_SECRET; SHARED_VPC_SECRET=$(cat /var/run/integration-tokens/SHARED_VPC_SECRET)
export TEST_OFFLINE_TOKEN; TEST_OFFLINE_TOKEN=$(cat /var/run/integration-tokens/TEST_OFFLINE_TOKEN)
export TEST_REGISTRATION_OFFLINE_TOKEN; TEST_REGISTRATION_OFFLINE_TOKEN=$(cat /var/run/integration-tokens/TEST_REGISTRATION_OFFLINE_TOKEN)
export TEST_SREP_OFFLINE_TOKEN; TEST_SREP_OFFLINE_TOKEN=$(cat /var/run/integration-tokens/TEST_SREP_OFFLINE_TOKEN)
export TEST_SUPPORT_OFFLINE_TOKEN; TEST_SUPPORT_OFFLINE_TOKEN=$(cat /var/run/integration-tokens/TEST_SUPPORT_OFFLINE_TOKEN)
export TEST_USER_ACCESS_KEY_ID; TEST_USER_ACCESS_KEY_ID=$(cat /var/run/integration-tokens/TEST_USER_ACCESS_KEY_ID)
export TEST_USER_SECRET; TEST_USER_SECRET=$(cat /var/run/integration-tokens/TEST_USER_SECRET)

./run_integration_full_cycle_tests.sh
