#!/usr/bin/env bash

set -o errexit
set -o nounset
set -o pipefail
set -x

which aws
export AWS_SHARED_CREDENTIALS_FILE=${CLUSTER_PROFILE_DIR}/.awscred
mkdir -p $HOME/.aws
aws configure set profile default
aws configure set region "$LEASED_RESOURCE"
aws configure get region
aws_region=${REGION:-$LEASED_RESOURCE}
export AWS_DEFAULT_REGION=$aws_region
source scripts/netobserv.sh
deploy_lokistack
deploy_kafka
deploy_netobserv
createFlowCollector "-p KafkaConsumerReplicas=${KAFKA_CONSUMER_REPLICAS}"

if [[ $PATCH_EBPFAGENT_IMAGE == "true" && -n $EBPFAGENT_PR_IMAGE ]]; then
    patch_netobserv "ebpf" "$EBPFAGENT_PR_IMAGE"
fi

if [[ $PATCH_FLOWLOGS_IMAGE == "true" && -n $FLP_PR_IMAGE ]]; then
    patch_netobserv "flp" "$FLP_PR_IMAGE"
fi

# get NetObserv metadata 
NETOBSERV_RELEASE=$(oc get pods -l app=netobserv-operator -o jsonpath="{.items[*].spec.containers[0].env[?(@.name=='OPERATOR_CONDITION_NAME')].value}" -A)
LOKI_RELEASE=$(oc get sub -n openshift-operators-redhat loki-operator -o jsonpath="{.status.currentCSV}")
KAFKA_RELEASE=$(oc get sub -n openshift-operators amq-streams  -o jsonpath="{.status.currentCSV}")
opm --help
if [[ $INSTALLATION_SOURCE == "Internal" || -n $DOWNSTREAM_IMAGE ]]; then
    NOO_BUNDLE_INFO=$(scripts/build_info.sh)
elif [[ $INSTALLATION_SOURCE == "Source" ]]; then
    if [[ -n $UPSTREAM_IMAGE ]]; then
        NOO_BUNDLE_INFO=${UPSTREAM_IMAGE##*:}
    else
        # Currently hardcoded as main until https://issues.redhat.com/browse/NETOBSERV-2054 is fixed
        NOO_BUNDLE_INFO="v0.0.0-sha-main"
    fi
fi


export METADATA="{\"release\": \"$NETOBSERV_RELEASE\", \"loki_version\": \"$LOKI_RELEASE\", \"kafka_version\": \"$KAFKA_RELEASE\", \"noo_bundle_info\":\"$NOO_BUNDLE_INFO\"}"

echo "$METADATA" >> "$SHARED_DIR/additional_params.json"
