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
export EMAIL_ID_FOR_RESULTS_SHEET="openshift-netobserv-team@redhat.com"
NOO_BUNDLE_VERSION=$(jq '.noo_bundle_info' < "$SHARED_DIR/$WORKLOAD-index_data.json")
export NOO_BUNDLE_VERSION

UUID=$(jq '.uuid' < "$SHARED_DIR/$WORKLOAD-index_data.json")
START_TIME=$(jq '.startDateUnixTimestamp' < "$SHARED_DIR/$WORKLOAD-index_data.json")
END_TIME=$(jq '.endDateUnixTimestamp' < "$SHARED_DIR/$WORKLOAD-index_data.json")

INGRESS_PERF_END_TIME=$(jq '.endDateUnixTimestamp' < "$SHARED_DIR/ingress-perf-index_data.json")

# strip quotes
UUID=${UUID//\"/}
START_TIME=${START_TIME//\"/}
END_TIME=${END_TIME//\"/}
INGRESS_PERF_END_TIME=${INGRESS_PERF_END_TIME//\"/}

# cluster-density-v2 takes longer to complete than ingress-perf
if [[ $WORKLOAD == "node-density-heavy" ]]; then
    END_TIME=$INGRESS_PERF_END_TIME
fi

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
    python scripts/nope.py --starttime "$START_TIME" --endtime "$END_TIME" --uuid "$UUID" --noo-bundle-version "$NOO_BUNDLE_VERSION"
    cp -r /tmp/data "$ARTIFACT_DIR"
}

function get_baseline(){
    pushd /scripts
    python nope.py baseline --fetch "$WORKLOAD"
    BASELINE_UUID=$(jq '.BASELINE_UUID' < /tmp/data/baseline.json)
    export BASELINE_UUID
}

function generate_metrics_sheet(){
    pushd /tmp
    git clone -b main --depth=1 $E2E_BENCHMARKING_REPO_URL
    export CONFIG_LOC="$PWD/scripts/queries"
    export COMPARISON_CONFIG="netobserv_touchstone_statistics_config.json"
    export ES_SERVER="https://$ES_USERNAME:$ES_PASSWORD@search-ocp-qe-perf-scale-test-elk-hcm7wtsqpxy7xogbu72bor4uve.us-east-1.es.amazonaws.com"
    export GEN_CSV=true
    pushd e2e-benchmarking/utils && source compare.sh
    # generate metrics sheet
    run_benchmark_comparison > "$ARTIFACT_DIR/benchmark_csv.log"
}

function update_sheet(){
    pushd /scripts/sheets
    enable_venv
    install_requirements requirements.txt
    python noo_perfsheets_update.py --sheet-id "$1" --uuid1 "$UUID" --uuid2 "$BASELINE_UUID" --service-account "$GSHEET_KEY_LOCATION"
}

function do_comparison(){
    pushd /tmp
    export TOLERANCE_LOC="$PWD/scripts/queries"
    export TOLERANCY_RULES="netobserv_touchstone_tolerancy_rules.yaml"
    export COMPARISON_CONFIG="netobserv_touchstone_tolerancy_config.json"
    export ES_SERVER_BASELINE="https://$ES_USERNAME:$ES_PASSWORD@search-ocp-qe-perf-scale-test-elk-hcm7wtsqpxy7xogbu72bor4uve.us-east-1.es.amazonaws.com"
    pushd e2e-benchmarking/utils && source compare.sh
    run_benchmark_comparison > "$ARTIFACT_DIR/benchmark_comp.log"
    # get the SHEET ID from the benchmark_comparison run logs
    COMP_SHEET_ID=$(grep Google "$ARTIFACT_DIR/benchmark_comp.log" | awk '{print $6}')
    update_sheet "$COMP_SHEET_ID"
}

upload_metrics
generate_metrics_sheet
get_baseline
do_comparison
update_sheet
