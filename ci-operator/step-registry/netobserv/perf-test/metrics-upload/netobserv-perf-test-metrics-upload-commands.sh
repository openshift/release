#!/usr/bin/env bash

set -o pipefail
set -o nounset

ES_USERNAME=$(cat /secret/username)
ES_PASSWORD=$(cat /secret/password)
export ES_SERVER="https://$ES_USERNAME:$ES_PASSWORD@search-ocp-qe-perf-scale-test-elk-hcm7wtsqpxy7xogbu72bor4uve.us-east-1.es.amazonaws.com"

set -x

function get_es_data(){
    uuid=$1
    # do a term query for exact matching
    query=$(jq -n --arg uuid "$uuid" '{"query":{"term":{"uuid.keyword": $uuid}}}')
    index_results="$ARTIFACT_DIR/${uuid}_index_data.json"
    curl -sS -k -X GET -H 'Content-Type: application/json' "$ES_SERVER/perf_scale_ci*/_search" -d "$query" -o "$index_results"
    res_len=$(jq '.hits.hits | length' "$index_results")

    # validate if there is record found for a UUID
    if [[ $res_len != "1" ]]; then
        echo "could not find match for UUID: $uuid" && exit 1 
    fi
    echo "$index_results"
}

export ES_PASSWORD
export ES_USERNAME
WORKLOAD_UUID_FILE="$SHARED_DIR/$WORKLOAD-uuid.txt"
INGRESS_PERF_UUID_FILE="$SHARED_DIR/ingress-perf-uuid.txt"

if [[ ! -f $WORKLOAD_UUID_FILE || ! -f $INGRESS_PERF_UUID_FILE ]]; then
    echo "UUID file not found for $WORKLOAD or ingress-perf" && exit 1
fi

UUID=$(cat "$WORKLOAD_UUID_FILE")
INGRESS_PERF_UUID=$(cat "$INGRESS_PERF_UUID_FILE")
# strip quotes
export UUID=${UUID//\"/}

workload_index_results=$(get_es_data "$UUID") 
ingress_perf_index_results=$(get_es_data "$INGRESS_PERF_UUID")

START_TIME=$(jq '.hits.hits[0]._source.startDate' "$workload_index_results" | xargs -I {} date -d {} +%s)
END_TIME=$(jq '.hits.hits[0]._source.endDate' "$workload_index_results" | xargs -I {} date -d {} +%s)

INGRESS_PERF_END_TIME=$(jq '.hits.hits[0]._source.endDate' "$ingress_perf_index_results" | xargs -I {} date -d {} +%s)

NOO_BUNDLE_VERSION=$(jq '.hits.hits[0]._source.noo_bundle_info' "$workload_index_results")
export NOO_BUNDLE_VERSION=${NOO_BUNDLE_VERSION//\"/}


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
