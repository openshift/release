#!/usr/bin/env bash

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

gather_debug_for_cluster_under_test
poll_for_system_test_images "3600"


ls -lh "$SHARED_DIR"

# Essentially replicates reuse_config_part_1
# There might be logic in here that is unnecessary
info "Reusing config from a prior part 1 e2e test"

export POD_SECURITY_POLICIES="false"

export_test_environment
setup_deployment_env false false
#export_default_TLS_certs "$DEPLOY_DIR/default_TLS_certs"
default_TLS_certs_path_prefix="${SHARED_DIR}/default_TLS_certs-"
export ROX_DEFAULT_TLS_CERT_FILE="${default_TLS_certs_path_prefix}tls.crt"
export ROX_DEFAULT_TLS_KEY_FILE="${default_TLS_certs_path_prefix}tls.key"
export DEFAULT_CA_FILE="${default_TLS_certs_path_prefix}ca.crt"
ROX_TEST_CA_PEM="$(cat "${default_TLS_certs_path_prefix}ca.crt")"
export ROX_TEST_CA_PEM="$ROX_TEST_CA_PEM"
export ROX_TEST_CENTRAL_CN="custom-tls-cert.central.stackrox.local"
export TRUSTSTORE_PATH="${default_TLS_certs_path_prefix}keystore.p12"

#export_client_TLS_certs "$DEPLOY_DIR/client_TLS_certs"
client_TLS_certs_path_prefix="${SHARED_DIR}/client_TLS_certs-"
export KEYSTORE_PATH="${client_TLS_certs_path_prefix}keystore.p12"
export CLIENT_CA_PATH="${client_TLS_certs_path_prefix}ca.crt"
export CLIENT_CERT_PATH="${client_TLS_certs_path_prefix}tls.crt"
export CLIENT_KEY_PATH="${client_TLS_certs_path_prefix}tls.key"

create_webhook_server_port_forward
#export_webhook_server_certs "$DEPLOY_DIR/webhook_server_certs"
GENERIC_WEBHOOK_SERVER_CA_CONTENTS="$(cat "${SHARED_DIR}/webhook_server_certs-ca.crt")"
export GENERIC_WEBHOOK_SERVER_CA_CONTENTS="$GENERIC_WEBHOOK_SERVER_CA_CONTENTS"

get_ECR_docker_pull_password

wait_for_api
#export_central_basic_auth_creds
export ROX_USERNAME="admin"
ROX_PASSWORD="$(cat "${SHARED_DIR}"/central-admin-password)"
export ROX_PASSWORD="$ROX_PASSWORD"

export CLUSTER="${ORCHESTRATOR_FLAVOR^^}"

# Essentially replicates test_part_1
# There might be logic in here that is unnecessary
info "QA Automation Platform Part 1"

if [[ "${ORCHESTRATOR_FLAVOR}" == "openshift" ]]; then
    oc get scc qatest-anyuid || oc create -f "qa-tests-backend/src/k8s/scc-qatest-anyuid.yaml"
fi

export CLUSTER="${ORCHESTRATOR_FLAVOR^^}"

# TODO :: Why is this here?
rm -f FAIL

if is_openshift_CI_rehearse_PR; then
    info "On an openshift rehearse PR, running BAT tests only..."
    test_target="bat-test"
elif is_in_PR_context && pr_has_label ci-all-qa-tests; then
    info "ci-all-qa-tests label was specified, so running all QA tests..."
    test_target="test"
elif is_in_PR_context; then
    info "In a PR context without ci-all-qa-tests, running BAT tests only..."
    test_target="bat-test"
else
    info "Running all QA tests by default..."
    test_target="test"
fi

update_job_record "test_target" "${test_target}"

make -C qa-tests-backend "${test_target}" || touch FAIL

store_qa_test_results "part-1-tests"
[[ ! -f FAIL ]] || die "Part 1 tests failed"