#!/usr/bin/env bash

# !! WARNING !! There is currently a bug with single quotes in this script. It has to do with `handle_dangling_processes`
# in the stackrox repo.

# TODO :: Check if these files exist
# shellcheck source=/dev/null
source "scripts/ci/lib.sh"
# shellcheck source=/dev/null
source "tests/e2e/lib.sh"
# shellcheck source=/dev/null
source "scripts/ci/gcp.sh"
# shellcheck source=/dev/null
source "scripts/ci/sensor-wait.sh"
# shellcheck source=/dev/null
source "scripts/ci/create-webhookserver.sh"
# shellcheck source=/dev/null
source "tests/scripts/setup-certs.sh"
# shellcheck source=/dev/null
source "qa-tests-backend/scripts/lib.sh"

set -o nounset
set -o errexit
set -o pipefail

openshift_ci_mods
openshift_ci_import_creds
create_exit_trap

# Might not need some of these but adding for consistency for now
export CI_JOB_NAME="ocp-qa-e2e-tests"
export DEPLOY_STACKROX_VIA_OPERATOR="true"
export ORCHESTRATOR_FLAVOR="openshift"
export ROX_POSTGRES_DATASTORE="true"

# Sensor will not deploy without scaling
scripts/ci/openshift.sh scale_worker_nodes "1"

gather_debug_for_cluster_under_test
poll_for_system_test_images "3600"

# Primarily used to share the TLS certs for the ACS components
SHARED_STACKROX="${SHARED_DIR}/stackrox"
mkdir -p "$SHARED_STACKROX"

# Essentially replicates config_part_1
# There might be logic in here that is unnecessary
info "Deploying ACS components"

require_environment "ORCHESTRATOR_FLAVOR"
require_environment "KUBECONFIG"

DEPLOY_DIR="${SHARED_STACKROX}/deploy/${ORCHESTRATOR_FLAVOR}"
mkdir -p "$DEPLOY_DIR"

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
