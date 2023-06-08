#!/usr/bin/env bash

# TODO(blugo): Check if these files exist
# shellcheck source=/dev/null
source "scripts/ci/lib.sh"

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
export POD_SECURITY_POLICIES="false"

gather_debug_for_cluster_under_test
poll_for_system_test_images "3600"

# Get the certs to connect to the ACS components under test
# TODO(blugo): Make sure this file exists
tar -xf acs_test_certs.tar -C "deploy/${ORCHESTRATOR_FLAVOR}"
mv "${SHARED_DIR}/central-admin-password" "${DEPLOY_DIR}/central-deploy/password"

qa-tests-backend/scripts/run-part-1.sh reuse_config_part_1

qa-tests-backend/scripts/run-part-1.sh test_part_1
