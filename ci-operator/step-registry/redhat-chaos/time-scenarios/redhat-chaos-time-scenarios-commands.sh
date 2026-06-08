#!/bin/bash
set -o errexit

console_url=$(oc get routes -n openshift-console console -o jsonpath='{.spec.host}')
export HEALTH_CHECK_URL=https://$console_url
set -o nounset
set -o pipefail
set -x

typeset secretDir=/secret/es
ES_PASSWORD=$(<"${secretDir}/es-password--${CHAOS_TEAM_NAME}")
ES_USERNAME=$(<"${secretDir}/es-username--${CHAOS_TEAM_NAME}")
export ES_USERNAME
export ES_PASSWORD

case "${CHAOS_TEAM_NAME}" in
  chaos)
    ES_SERVER="https://search-ocp-qe-perf-scale-test-elk-hcm7wtsqpxy7xogbu72bor4uve.us-east-1.es.amazonaws.com"
    ;;
  lp-chaos)
    ES_SERVER="https://open-search.lp-chaos--svc--web-app.chaos.lp.devcluster.openshift.com"
    ;;
  *)
    ES_SERVER=""
    ;;
esac
export ES_SERVER

echo "kubeconfig loc $$KUBECONFIG"
echo "Using the flattened version of kubeconfig"
oc config view --flatten > /tmp/config
telemetry_password=$(cat "/secret/telemetry/telemetry_password")
export TELEMETRY_PASSWORD=$telemetry_password

export KUBECONFIG=/tmp/config
export ACTION=$ACTION
export OBJECT_TYPE=$OBJECT_TYPE     
export NAMESPACE=$TARGET_NAMESPACE
export CONTAINER_NAME=$CONTAINER_NAME
export LABEL_SELECTOR=$LABEL_SELECTOR
export KRKN_KUBE_CONFIG=$KUBECONFIG
export ENABLE_ALERTS=False

./time-scenarios/prow_run.sh
rc=$?
if [[ $TELEMETRY_EVENTS_BACKUP == "True" ]]; then
    cp /tmp/events.json ${ARTIFACT_DIR}/events.json
fi

echo "Finished running time scenario"
echo "Return code: $rc"
