#!/bin/bash

set -o nounset
set -o errexit
set -o pipefail
set -o verbose

unset GOFLAGS

export AWS_TEST_ACCOUNT_ID; AWS_TEST_ACCOUNT_ID=$(cat /var/run/integration-tokens/AWS_TEST_ACCOUNT_ID)
export AWS_TEST_REGIONS; AWS_TEST_REGIONS=$(cat /var/run/integration-tokens/AWS_TEST_REGIONS)
export JIRA_TOKEN; JIRA_TOKEN=$(cat /var/run/integration-tokens/JIRA_TOKEN)
export OSD_ADMIN_ACCESS_KEY_ID; OSD_ADMIN_ACCESS_KEY_ID=$(cat /var/run/integration-tokens/OSD_ADMIN_ACCESS_KEY_ID)
export OSD_ADMIN_SECRET; OSD_ADMIN_SECRET=$(cat /var/run/integration-tokens/OSD_ADMIN_SECRET)
export SHARED_VPC_ACCESS_KEY_ID; SHARED_VPC_ACCESS_KEY_ID=$(cat /var/run/integration-tokens/SHARED_VPC_ACCESS_KEY_ID)
export SHARED_VPC_SECRET; SHARED_VPC_SECRET=$(cat /var/run/integration-tokens/SHARED_VPC_SECRET)
export SMTP_DOMAIN; SMTP_DOMAIN=$(cat /var/run/integration-tokens/SMTP_DOMAIN)
export SMTP_PASSWORD; SMTP_PASSWORD=$(cat /var/run/integration-tokens/SMTP_PASSWORD)
export SMTP_PORT; SMTP_PORT=$(cat /var/run/integration-tokens/SMTP_PORT)
export SMTP_SERVER; SMTP_SERVER=$(cat /var/run/integration-tokens/SMTP_SERVER)
export SMTP_USER; SMTP_USER=$(cat /var/run/integration-tokens/SMTP_USER)
export TEST_CLIENT_ID; TEST_CLIENT_ID=$(cat /var/run/integration-tokens/TEST_CLIENT_ID)
export TEST_CLIENT_SECRET; TEST_CLIENT_SECRET=$(cat /var/run/integration-tokens/TEST_CLIENT_SECRET)
export TEST_GATEWAY_URL; TEST_GATEWAY_URL=$(cat /var/run/integration-tokens/TEST_GATEWAY_URL)
export TEST_NEGATIVE_TOGGLE_OFFLINE_TOKEN; TEST_NEGATIVE_TOGGLE_OFFLINE_TOKEN=$(cat /var/run/integration-tokens/TEST_NEGATIVE_TOGGLE_OFFLINE_TOKEN)
export TEST_OFFLINE_TOKEN; TEST_OFFLINE_TOKEN=$(cat /var/run/integration-tokens/TEST_OFFLINE_TOKEN)
export TEST_REGISTRATION_ID; TEST_REGISTRATION_ID=$(cat /var/run/integration-tokens/TEST_REGISTRATION_ID)
export TEST_REGISTRATION_OFFLINE_TOKEN; TEST_REGISTRATION_OFFLINE_TOKEN=$(cat /var/run/integration-tokens/TEST_REGISTRATION_OFFLINE_TOKEN)
export TEST_REGISTRATION_SECRET; TEST_REGISTRATION_SECRET=$(cat /var/run/integration-tokens/TEST_REGISTRATION_SECRET)
export TEST_SREP_ID; TEST_SREP_ID=$(cat /var/run/integration-tokens/TEST_SREP_ID)
export TEST_SREP_OFFLINE_TOKEN; TEST_SREP_OFFLINE_TOKEN=$(cat /var/run/integration-tokens/TEST_SREP_OFFLINE_TOKEN)
export TEST_SREP_SECRET; TEST_SREP_SECRET=$(cat /var/run/integration-tokens/TEST_SREP_SECRET)
export TEST_SUPPORT_ID; TEST_SUPPORT_ID=$(cat /var/run/integration-tokens/TEST_SUPPORT_ID)
export TEST_SUPPORT_OFFLINE_TOKEN; TEST_SUPPORT_OFFLINE_TOKEN=$(cat /var/run/integration-tokens/TEST_SUPPORT_OFFLINE_TOKEN)
export TEST_SUPPORT_SECRET; TEST_SUPPORT_SECRET=$(cat /var/run/integration-tokens/TEST_SUPPORT_SECRET)
export TEST_TERMS_OFFLINE_TOKEN; TEST_TERMS_OFFLINE_TOKEN=$(cat /var/run/integration-tokens/TEST_TERMS_OFFLINE_TOKEN)
export TEST_USER_ACCESS_KEY_ID; TEST_USER_ACCESS_KEY_ID=$(cat /var/run/integration-tokens/TEST_USER_ACCESS_KEY_ID)
export TEST_USER_SECRET; TEST_USER_SECRET=$(cat /var/run/integration-tokens/TEST_USER_SECRET)

./run_integration_tests.sh
