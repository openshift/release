#!/usr/bin/env bash
set -o errexit
set -o nounset
set -o pipefail
set -x


ES_USERNAME=$(cat /secret/username)
ES_PASSWORD=$(cat /secret/password)
export ES_PASSWORD
export ES_USERNAME
export GSHEET_KEY_LOCATION="/ga-gsheet/gcp-sa-account"

UUID=$(jq '.uuid' < "$SHARED_DIR/$WORKLOAD-index_data.json")
START_TIME=$(jq '.startDateUnixTimestamp' < "$SHARED_DIR/$WORKLOAD-index_data.json")
if [[ $WORKLOAD == "cluster-density-v2" ]]; then
    END_TIME=$(jq '.endDateUnixTimestamp' < "$SHARED_DIR/$WORKLOAD-index_data.json")
fi
# cluster-density takes longer to complete than ingress-perf
if [[ $WORKLOAD == "node-density-heavy" ]]; then
    # TODO: change to ingress-perf-index_data.json
    END_TIME=$(jq '.endDateUnixTimestamp' < "$SHARED_DIR/$WORKLOAD-index_data.json")
fi
# Currently hardcoded as main until https://issues.redhat.com/browse/NETOBSERV-2054 is fixed
if [[ $INSTALLATION_SOURCE == "Internal" ]]; then
    NOO_BUNDLE_VERSION=$(jq '.noo_bundle_info' < "$SHARED_DIR/netobserv_metadata.json")
else
    NOO_BUNDLE_VERSION="v0.0.0-main"
fi
export NOO_BUNDLE_VERSION

E2E_BENCHMARKING_REPO_URL="https://github.com/cloud-bulldozer/e2e-benchmarking"

function enable_venv() {
    python --version
    python3.9 --version
    python3.9 -m pip install virtualenv
    python3.9 -m virtualenv venv3
    source venv3/bin/activate
    python --version
}

function install_requirements(){
    python -m pip install -r "$1"
}


function upload_metrics(){
    install_requirements scripts/requirements.txt
    python scripts/nope.py "$NOPE_ARGS" --starttime "$START_TIME" --endtime "$END_TIME" --uuid "$UUID" --noo-bundle-version" $NOO_BUNDLE_VERSION"
}

function get_baseline(){
    python scripts/nope.py baseline --fetch "$WORKLOAD"
}

function generate_metrics_sheet(){
    git clone -b main --depth=1 $E2E_BENCHMARKING_REPO_URL
    export CONFIG_LOC="$PWD/scripts/queries"
    export COMPARISON_CONFIG="netobserv_touchstone_statistics_config.json"
    export ES_SERVER="https://$ES_USERNAME:$ES_PASSWORD@search-ocp-qe-perf-scale-test-elk-hcm7wtsqpxy7xogbu72bor4uve.us-east-1.es.amazonaws.com"
    export GEN_CSV=true
    cd e2e-benchmarking/utils && source compare.sh
    # generate metrics sheet
    run_benchmark_comparison > "$ARTIFACT_DIR"/benchmark_csv.log
}

function do_comparison(){
    export BASELINE_UUID
    export TOLERANCE_LOC="$PWD/scripts/queries"
    export TOLERANCY_RULES="netobserv_touchstone_tolerancy_rules.yaml"
    export COMPARISON_CONFIG="netobserv_touchstone_tolerancy_config.json"
    export ES_SERVER_BASELINE="https://$ES_USERNAME:$ES_PASSWORD@search-ocp-qe-perf-scale-test-elk-hcm7wtsqpxy7xogbu72bor4uve.us-east-1.es.amazonaws.com"
    pushd "$PWD" || exit
    cd e2e-benchmarking/utils && source compare.sh
    run_benchmark_comparison > "$ARTIFACT_DIR"/benchmark_comp.log
}

function update_sheet(){
    cd scripts/sheets || exit
    enable_venv
    install_requirements requirements.txt
    python noo_perfsheets_update.py --sheet-id "$COMP_SHEET_ID" --uuid1 "$UUID" --uuid2 "$BASELINE_UUID" --service-account "$GSHEET_KEY_LOCATION"
}

pushd "$PWD" || exit
upload_metrics
generate_metrics_sheet
popd || exit
get_baseline
BASELINE_UUID=$(jq '.BASELINE_UUID' < data/baseline.json)
export BASELINE_UUID
pushd "$PWD" || exit
do_comparison
COMP_SHEET_ID=$(grep Google "$ARTIFACT_DIR"/benchmark_comp.log | awk '{print $6}' )
export COMP_SHEET_ID
popd || exit
update_sheet
