#!/usr/bin/env bash

set -o pipefail
# disable nounset as e2e-benchmarking needs several variables to be set,
# and we're selectively setting variables to get comparison sheets.
set +o nounset

ES_USERNAME=$(cat /secret/username)
ES_PASSWORD=$(cat /secret/password)

set -x

export ES_PASSWORD
export ES_USERNAME
export GSHEET_KEY_LOCATION="/ga-gsheet/gcp-sa-account"
export EMAIL_ID_FOR_RESULTS_SHEET="openshift-netobserv-team@redhat.com"
NOO_BUNDLE_VERSION=$(jq '.noo_bundle_info' < "$SHARED_DIR/$WORKLOAD-index_data.json")
export NOO_BUNDLE_VERSION=${NOO_BUNDLE_VERSION//\"/}

UUID=$(jq '.uuid' < "$SHARED_DIR/$WORKLOAD-index_data.json")
START_TIME=$(jq '.startDateUnixTimestamp' < "$SHARED_DIR/$WORKLOAD-index_data.json")
END_TIME=$(jq '.endDateUnixTimestamp' < "$SHARED_DIR/$WORKLOAD-index_data.json")

INGRESS_PERF_END_TIME=$(jq '.endDateUnixTimestamp' < "$SHARED_DIR/ingress-perf-index_data.json")

# strip quotes
export UUID=${UUID//\"/}
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
    upload_metrics_rc=$?
    cp -r /tmp/data "$ARTIFACT_DIR"
}

function upload_baseline(){
    cd /scripts || exit
    install_requirements requirements.txt
    python nope.py baseline --upload "$UUID"
}

function get_baseline(){
    cd /scripts || exit
    install_requirements requirements.txt
    python nope.py baseline --fetch "$WORKLOAD"
    BASELINE_UUID=$(jq '.BASELINE_UUID' < /tmp/data/baseline.json)
    BASELINE_UUID=${BASELINE_UUID//\"/}
    export BASELINE_UUID
}

function generate_metrics_sheet(){
    cd /tmp || exit
    git clone -b master --depth=1 $E2E_BENCHMARKING_REPO_URL
    export CONFIG_LOC="/scripts/queries"
    export COMPARISON_CONFIG="netobserv_touchstone_statistics_config.json"
    export ES_SERVER="https://$ES_USERNAME:$ES_PASSWORD@search-ocp-qe-perf-scale-test-elk-hcm7wtsqpxy7xogbu72bor4uve.us-east-1.es.amazonaws.com"
    NETWORK_TYPE=$(oc get network.config/cluster -o jsonpath='{.spec.networkType}')
    export NETWORK_TYPE
    export TOLERANCY_RULES=""
    export ES_SERVER_BASELINE=""
    export GEN_JSON=false
    export GEN_CSV=true
    cd e2e-benchmarking/utils && source compare.sh
    # generate metrics sheet
    run_benchmark_comparison > "$ARTIFACT_DIR/benchmark_csv.log"
    cp "/tmp/$WORKLOAD-$UUID/$UUID.csv" "$ARTIFACT_DIR/${UUID}_metrics.csv"
}

function update_sheet(){
    cd /scripts/sheets || exit
    enable_venv
    install_requirements requirements.txt
    python noo_perfsheets_update.py --sheet-id "$1" --uuid1 "$UUID" --uuid2 "$BASELINE_UUID" --service-account "$GSHEET_KEY_LOCATION"
}

function do_comparison(){
    cd /tmp || exit
    rm -rf /tmp/$WORKLOAD-$UUID/$UUID.csv || true
    export TOLERANCE_LOC="/scripts/queries"
    export TOLERANCY_RULES="netobserv_touchstone_tolerancy_rules.yaml"
    export COMPARISON_CONFIG="netobserv_touchstone_tolerancy_config.json"
    export ES_SERVER_BASELINE="https://$ES_USERNAME:$ES_PASSWORD@search-ocp-qe-perf-scale-test-elk-hcm7wtsqpxy7xogbu72bor4uve.us-east-1.es.amazonaws.com"
    export GEN_CSV=true
    cd e2e-benchmarking/utils && source compare.sh
    COMP_LOG="$ARTIFACT_DIR/benchmark_comp.log"
    run_benchmark_comparison > "$COMP_LOG"
    comp_rc=$?
    cp "/tmp/$WORKLOAD-$UUID/$UUID.csv" "$ARTIFACT_DIR/${UUID}_comparison.csv"
    # get the SHEET ID from the benchmark_comparison run logs
    if [[ -f $COMP_LOG ]]; then
        COMP_SHEET_ID=$(grep Google "$COMP_LOG" | awk -F'/' '{print $NF}' | awk '{print $1}')
        update_sheet "$COMP_SHEET_ID"
    fi
    echo $comp_rc
}

upload_metrics
if [[ $upload_metrics_rc -gt 0 ]]; then
    echo "Metrics uploading to ES failed, exiting!!!"
    exit "$upload_metrics_rc"
fi

generate_metrics_sheet
get_baseline

if [[ -n $BASELINE_UUID ]]; then
    # get the last value from output of do_comparison for the return code of comparison
    comparison_rc=$(do_comparison | tail -n 1)
    if [[ $comparison_rc -gt 0 ]]; then
        echo "Comparison with Baseline failed!!!"
    else
        echo "All metrics are within tolerance limits compared to current baseline."
        # upload Baselines only for periodic job triggers.
        if [[ -n $JOB_NAME && $JOB_NAME =~ ^"periodic" ]]; then
            echo "Uploading $UUID as new baseline for $WORKLOAD"
            upload_baseline 
        fi
    fi
else
    echo "Couldn't fetch baseline UUID for workload $WORKLOAD from ES"
    exit 1
fi
exit "$comparison_rc"
