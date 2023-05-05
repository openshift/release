#!/bin/bash

set -o nounset
set -o errexit
set -o pipefail

# Check "qa-tests-backend/scripts/run-part-1.sh"

# shellcheck source=/dev/null
source "qa-tests-backend/scripts/run-part-1.sh"


SHARED_STACKROX="${SHARED_DIR}/stackrox"
mkdir -p "$SHARED_STACKROX"

export ORCHESTRATOR_FLAVOR="openshift"

# Essential replicat config_part_1
# There might be logic in here that is unnecessary
info "Configuring the cluster to run part 1 of e2e tests"

require_environment "ORCHESTRATOR_FLAVOR"
require_environment "KUBECONFIG"

DEPLOY_DIR="${SHARED_STACKROX}/deploy/${ORCHESTRATOR_FLAVOR}"

export_test_environment

setup_gcp
setup_deployment_env false false
setup_podsecuritypolicies_config
remove_existing_stackrox_resources
setup_default_TLS_certs "$DEPLOY_DIR/default_TLS_certs"

deploy_stackrox "$DEPLOY_DIR/client_TLS_certs"

deploy_default_psp
deploy_webhook_server "$DEPLOY_DIR/webhook_server_certs"
get_ECR_docker_pull_password
