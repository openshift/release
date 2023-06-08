#!/usr/bin/env bash

# !! WARNING !! There is currently a bug with single quotes in this script. It has to do with `handle_dangling_processes`
# in the stackrox repo.

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

# Sensor will not deploy without scaling
scripts/ci/openshift.sh scale_worker_nodes "1"

gather_debug_for_cluster_under_test
poll_for_system_test_images "3600"

# Essentially replicates config_part_1
# There might be logic in here that is unnecessary
qa-tests-backend/scripts/run-part-1.sh config_part_1

# We need to move some files because the shared directory for OpenShift CI steps does not support directories
# This strange command is to get _only_ files in the directories we need
tar -cvf acs_test_certs.tar "deploy/${ORCHESTRATOR_FLAVOR}"

# TODO(blugo): There must be a better way to do this
echo "$ROX_PASSWORD" > "$SHARED_DIR/central-admin-password"
