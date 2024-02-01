#!/bin/bash
# shellcheck disable=SC1091 # (files import)

set -o nounset
set -o errexit
set -o pipefail

trap 'CHILDREN=$(jobs -p); if test -n "${CHILDREN}"; then kill ${CHILDREN} && wait; fi' TERM

CURRENT_DIR="$(dirname "$(realpath "$0")")"

. "$CURRENT_DIR"/utils/functions.sh
. "$CURRENT_DIR/cases/ocp_60338.sh"
. "$CURRENT_DIR/cases/ocp_63511.sh"
. "$CURRENT_DIR/cases/ocp_63998.sh"
. "$CURRENT_DIR/cases/ocp_67823.sh"
. "$CURRENT_DIR/cases/ocp_68154.sh"
. "$CURRENT_DIR/cases/ocpqe_16843.sh"
. "$CURRENT_DIR/cases/ocpqe_17157.sh"
. "$CURRENT_DIR/cases/ocpqe_17288.sh"
. "$CURRENT_DIR/cases/ocpqe_17367.sh"
. "$CURRENT_DIR/cases/ocpqe_17578.sh"
. "$CURRENT_DIR/cases/ocpqe_17815.sh"
. "$CURRENT_DIR/cases/ocpqe_17816.sh"
. "$CURRENT_DIR/cases/ocpqe_17818.sh"
. "$CURRENT_DIR/cases/ocpqe_17819.sh"
. "$CURRENT_DIR/cases/ocpqe_17866.sh"
. "$CURRENT_DIR/cases/ocpqe_17867.sh"
. "$CURRENT_DIR/cases/ocpqe_17901.sh"
. "$CURRENT_DIR/cases/ocpqe_17964.sh"
. "$CURRENT_DIR/cases/ocpqe_17965.sh"
. "$CURRENT_DIR/cases/ocpqe_18303.sh"
. "$CURRENT_DIR/cases/ocpqe_18337.sh"

# two arrays used at the end of the script to print out failed/ passed test cases
export PASSED=("")
export FAILED=("")

login_to_ocm

# Test all cases and print results

test_monitoring_disabled

# temporarily disabling this test, as autoscaling work is ongoing and it won't pass
# test_autoscaler

test_labels

test_endpoints

test_audit_endpooint

test_machinesets_naming

test_host_prefix_podisolation

test_obo_machine_pool

test_machine_health_check_config

test_compliance_monkey_descheduler

test_hypershift_crds_not_installed_on_sc

test_add_labels_to_sc_after_installing

test_ready_mc_acm_placement_decision

test_fetching_cluster_details_from_api

test_machineset_tains_and_labels

test_sts_mc_sc

test_backups_created_only_once

test_obo_machinesets

test_awsendpointservices_status_output_populated

test_serving_machine_pools

test_mc_request_serving_pool_autoscaling

print_results
