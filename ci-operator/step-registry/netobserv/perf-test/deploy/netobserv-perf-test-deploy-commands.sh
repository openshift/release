#!/usr/bin/env bash

set -o errexit
set -o nounset
set -o pipefail
set -x

if [[ -n $MULTISTAGE_PARAM_OVERRIDE_INSTALLATION_SOURCE ]] ; then
    export INSTALLATION_SOURCE="$MULTISTAGE_PARAM_OVERRIDE_INSTALLATION_SOURCE"
fi

if [[ -n $MULTISTAGE_PARAM_OVERRIDE_DOWNSTREAM_IMAGE ]] ; then
    export DOWNSTREAM_IMAGE="$MULTISTAGE_PARAM_OVERRIDE_DOWNSTREAM_IMAGE"
fi

if [[ -n $MULTISTAGE_PARAM_OVERRIDE_UPSTREAM_IMAGE ]] ; then
    export UPSTREAM_IMAGE="$MULTISTAGE_PARAM_OVERRIDE_UPSTREAM_IMAGE"
fi


which aws
export AWS_SHARED_CREDENTIALS_FILE=${CLUSTER_PROFILE_DIR}/.awscred
mkdir -p $HOME/.aws
aws configure set profile default
aws configure set region "$LEASED_RESOURCE"
aws configure get region
aws_region=${REGION:-$LEASED_RESOURCE}
export AWS_DEFAULT_REGION=$aws_region
source scripts/netobserv.sh

if [[ ${LOKI_OPERATOR:-} != "None" ]] && [[ -z ${MULTISTAGE_PARAM_OVERRIDE_LOKI_ENABLE:-} ]]; then
    deploy_lokistack
fi

if [[ ${DEPLOYMENT_MODEL:-} == "Kafka" ]]; then
    deploy_kafka
fi

deploy_netobserv

PARAMETERS="-p"

if [[ -n ${DEPLOYMENT_MODEL:-} ]]; then
    PARAMETERS+=" DeploymentModel=${DEPLOYMENT_MODEL}"
fi

if [[ -n ${MULTISTAGE_PARAM_OVERRIDE_SAMPLING:-} ]]; then
    PARAMETERS+=" EBPFSamplingRate=${MULTISTAGE_PARAM_OVERRIDE_SAMPLING}"
fi

if [[ -n ${MULTISTAGE_PARAM_OVERRIDE_FEATURES:-} ]]; then
    PARAMETERS+=" EBPFeatures=${MULTISTAGE_PARAM_OVERRIDE_FEATURES}"
fi

if [[ -n ${MULTISTAGE_PARAM_OVERRIDE_LOKI_ENABLE:-} ]] || [[ ${LOKI_OPERATOR:-} == "None" ]]; then
    PARAMETERS+=" LokiEnable=false"
fi

if [[ ${FLP_CONSUMER_REPLICAS:-} ]]; then
    PARAMETERS+=" KafkaConsumerReplicas=${FLP_CONSUMER_REPLICAS}"
fi

createFlowCollector ${PARAMETERS}


if [[ $PATCH_EBPFAGENT_IMAGE == "true" && -n $EBPFAGENT_PR_IMAGE ]]; then
    patch_netobserv "ebpf" "$EBPFAGENT_PR_IMAGE"
fi

if [[ $PATCH_FLOWLOGS_IMAGE == "true" && -n $FLP_PR_IMAGE ]]; then
    patch_netobserv "flp" "quay.io/netobserv/flowlogs-pipeline:08e411a2"
fi


oc process --ignore-unknown-parameters=true -f /scripts/netobserv/flows_v1beta2_flowcollector.yaml -p DeploymentModel=Kafka KafkaConsumerReplicas=6 -n default -o yaml >"$ARTIFACT_DIR"/flowcollector.yaml

oc apply -f "$ARTIFACT_DIR"/flowcollector.yaml


# oc patch flowcollector/cluster --type=merge -p '{
#   "spec": {
#     "processor": {
#       "informers": {
#         "enabled": true
#         }
#       }
#     }
#   }
# }'


waitForFlowcollectorReady() {
  echo "====> Waiting for eBPF pods to be ready"
  timeout=30
  while [ $timeout -lt 300 ]; do
    oc get daemonset netobserv-ebpf-agent -n netobserv-privileged && break
    sleep 10
    timeout=$((timeout+10))
  done
  sleep 60
  timeout=0
  while [ $timeout -lt 3600 ]; do
    agentsDesired=$(oc get daemonset netobserv-ebpf-agent -n netobserv-privileged -o jsonpath='{.status.desiredNumberScheduled}')
    agentsReady=$(oc get daemonset netobserv-ebpf-agent -n netobserv-privileged -o jsonpath='{.status.numberReady}')
    [[ $agentsDesired -eq "$agentsReady" ]] && break
    sleep 30
    timeout=$((timeout+30))
    echo "====> ebpf agents are not ready after $timeout, checking again..."
  done
  oc wait --timeout=1200s --for=condition=ready flowcollector cluster
}

waitForFlowcollectorReady


# get NetObserv metadata
NETOBSERV_RELEASE=$(oc get pods -l app=netobserv-operator -o jsonpath="{.items[*].spec.containers[0].env[?(@.name=='OPERATOR_CONDITION_NAME')].value}" -A)

# Get Loki version or set to N/A
LOKI_RELEASE="N/A"
if [[ ${LOKI_OPERATOR:-} != "None" ]] && [[ -z ${MULTISTAGE_PARAM_OVERRIDE_LOKI_ENABLE:-} ]]; then
    LOKI_RELEASE=$(oc get sub -n openshift-operators-redhat loki-operator -o jsonpath="{.status.currentCSV}")
fi

# Get Kafka version or set to N/A
KAFKA_RELEASE="N/A"
if [[ ${DEPLOYMENT_MODEL:-} == "Kafka" ]]; then
    KAFKA_RELEASE=$(oc get sub -n openshift-operators amq-streams  -o jsonpath="{.status.currentCSV}")
fi

SAMPLING=$(oc get flowcollector/cluster -o jsonpath='{.spec.agent.ebpf.sampling}')

opm --help
NOO_BUNDLE_INFO=$(scripts/build_info.sh)

export METADATA="{\"release\": \"$NETOBSERV_RELEASE\", \"loki_version\": \"$LOKI_RELEASE\", \"kafka_version\": \"$KAFKA_RELEASE\", \"deployment_model\": \"$DEPLOYMENT_MODEL\", \"noo_bundle_info\":\"$NOO_BUNDLE_INFO\", \"sampling\":\"$SAMPLING\"}"

echo "$METADATA" >> "$SHARED_DIR/additional_params.json"
cp "$SHARED_DIR/additional_params.json" "$ARTIFACT_DIR/additional_params.json"
