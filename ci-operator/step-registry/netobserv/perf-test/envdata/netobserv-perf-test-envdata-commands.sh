#!/usr/bin/env bash

set -o nounset
set -o errexit
set -o pipefail


NETOBSERV_RELEASE=$(oc get pods -l app=netobserv-operator -o jsonpath="{.items[*].spec.containers[0].env[?(@.name=='OPERATOR_CONDITION_NAME')].value}" -A)
LOKI_RELEASE=$(oc get sub -n openshift-operators-redhat loki-operator -o jsonpath="{.status.currentCSV}")
KAFKA_RELEASE=$(oc get sub -n openshift-operators amq-streams  -o jsonpath="{.status.currentCSV}")

if [[ $INSTALLATION_SOURCE == "Internal" ]]; then
    NOO_BUNDLE_INFO=$(./scripts/build_info.sh)
fi

# TODO, Add:
# PR info?

NETOBSERV_METADATA="{\"release\": \"$NETOBSERV_RELEASE\", \"loki_version\": \"$LOKI_RELEASE\", \"kafka_version\": \"$KAFKA_RELEASE\", \"noo_bundle_info\"=\"$NOO_BUNDLE_INFO\"}"

if [ -d "${SHARED_DIR}" ]; then 
    echo "$NETOBSERV_METADATA" > "${SHARED_DIR}"/netobserv_metadata.json
fi

echo "$NETOBSERV_METADATA" > "${ARTIFACT_DIR}"/netobserv_metadata.json
