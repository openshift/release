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

export ES_PASSWORD
export ES_USERNAME

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
export KUBECONFIG=/tmp/config

export KRKN_KUBE_CONFIG=$KUBECONFIG
export NAMESPACE=$TARGET_NAMESPACE 
telemetry_password=$(cat "/secret/telemetry/telemetry_password")
export TELEMETRY_PASSWORD=$telemetry_password

collect_artifacts() {
  local rc=$?
  set +o errexit
  # Done running the test
  if [[ "${TELEMETRY_EVENTS_BACKUP:-}" == "True" && -f /tmp/events.json ]]; then
    cp /tmp/events.json "${ARTIFACT_DIR}/events.json"
  fi
  if [[ -f /tmp/report.out.pdf ]]; then
    cp /tmp/report.out.pdf "${ARTIFACT_DIR}/kraken.report.pdf"
  fi
  exit "$rc"
}

trap collect_artifacts EXIT

set -euxo pipefail; shopt -s inherit_errexit

./namespace-scenarios/prow_run.sh

