#!/usr/bin/env bash

set -o pipefail
set -o nounset

ES_USERNAME=$(cat /secret/username)
ES_PASSWORD=$(cat /secret/password)

set -x

export ES_PASSWORD
export ES_USERNAME
export EMAIL_ID_FOR_RESULTS_SHEET="openshift-netobserv-team@redhat.com"
NOO_BUNDLE_VERSION=$(jq '.noo_bundle_info' < "$SHARED_DIR/$WORKLOAD-index_data.json")
export NOO_BUNDLE_VERSION=${NOO_BUNDLE_VERSION//\"/}

UUID=$(jq '.uuid' < "$SHARED_DIR/$WORKLOAD-index_data.json")
START_TIME=$(jq '.startDate' < "$SHARED_DIR/$WORKLOAD-index_data.json" | xargs -I {} date -d {} +%s)
END_TIME=$(jq '.endDate' < "$SHARED_DIR/$WORKLOAD-index_data.json" | xargs -I {} date -d {} +%s)

INGRESS_PERF_END_TIME=$(jq '.endDate' < "$SHARED_DIR/ingress-perf-index_data.json" | xargs -I {} date -d {} +%s)

# strip quotes
export UUID=${UUID//\"/}

# cluster-density-v2 takes longer to complete than ingress-perf
if [[ $WORKLOAD == "node-density-heavy" ]]; then
    END_TIME=$INGRESS_PERF_END_TIME
fi

function install_requirements(){
    python -m pip install -r "$1"
}

function upload_metrics(){
    install_requirements scripts/requirements.txt
    python scripts/nope.py --starttime "$START_TIME" --endtime "$END_TIME" --uuid "$UUID" --noo-bundle-version "$NOO_BUNDLE_VERSION"
    upload_metrics_rc=$?
    cp -r /tmp/data "$ARTIFACT_DIR"
}

upload_metrics
if [[ $upload_metrics_rc -gt 0 ]]; then
    echo "Metrics uploading to ES failed!!!"
fi
exit "$upload_metrics_rc"
