#!/bin/bash
set -o errexit

# Map results by setting identifier prefix in testsuite names for CR reporting.
# Merge original results into a single file and send to shared dir for
# mpiit-data-router-reporter.
if [ "${MAP_TESTS:-}" = "true" ]; then
    eval "$(
        typeset -a _fURL=()
        type -t wget 1>/dev/null && _fURL=(wget -qO-) || _fURL=(curl -fsSL)
        "${_fURL[@]}" \
https://raw.githubusercontent.com/RedHatQE/OpenShift-LP-QE--Tools/refs/heads/main/libs/bash/ci-operator/interop/common/ExitTrap--PostProcessPrep.sh
    )"; trap '
        LP_IO__ET_PPP__NEW_TS_NAME="${DR__RP__CR_COMP_NAME}--%s" \
            ExitTrap--PostProcessPrep junit--redhat-chaos-container-scenarios-etcd-hangup.xml
    ' EXIT
fi

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
export ENABLE_ALERTS=False
telemetry_password=$(cat "/secret/telemetry/telemetry_password")
export TELEMETRY_PASSWORD=$telemetry_password

export EXPECTED_RECOVERY_TIME=$CONTAINER_ETCD_RECOVERY_TIME

console_url=$(oc get routes -n openshift-console console -o jsonpath='{.spec.host}')
export HEALTH_CHECK_URL=https://$console_url
set -o nounset
set -o pipefail
set -x

./container-scenarios/prow_run.sh
rc=$?
if [[ $TELEMETRY_EVENTS_BACKUP == "True" ]]; then
    cp /tmp/events.json ${ARTIFACT_DIR}/events.json
fi
echo "Finished running container scenarios"
echo "Return code: $rc"
