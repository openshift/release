#!/bin/bash
set -x
set -o errexit
set -o nounset
set -o pipefail

export STORE_PATH="${ARTIFACT_DIR}/junit/resource-watch-store"
mkdir -p "${STORE_PATH}"

log() {
  echo "[$(date -Is)] $1"
}

wait_for_network_config_conditions(){
      local timeout=${1}
      shift 1

      local conditions=("$@")
      local end_time=$((SECONDS + timeout))

      while ((SECONDS < end_time)); do
          all_conditions_met=true

          for condition in "${conditions[@]}"; do
              if ! oc wait network.config.openshift.io cluster --for="condition=$condition" --timeout=0 &>/dev/null; then
                  log "Condition not met: ${condition}"
                  all_conditions_met=false
                  break
              fi
          done

          if $all_conditions_met; then
              return 0
          fi

          sleep 10
      done

      return 1
}

function stop_monitor() {
  e=0
  log "killing resource watch"
  CHILDREN=$(jobs -p)
  if test -n "${CHILDREN}"
  then
    kill "${CHILDREN}" && wait
  fi

  # Move the test results into a file that matches the junit selector used by CI
  mv "$STORE_PATH"/e2e-monitor-tests_.xml "${ARTIFACT_DIR}/junit_e2e_migration.xml"
  if jq '.Tests | length > 0' $STORE_PATH/test-failures-summary_monitor.json | grep -q true; then
      log "Some tests failed"
      e=1
  fi
  tar -czC "$STORE_PATH" -f "${ARTIFACT_DIR}/resource-watch-store.tar.gz" .
  rm -rf "$STORE_PATH"

  log "ended resource watch gracefully"s
  exit $e
}
#trap "stop_monitor" EXIT


TARGET=${TARGET:-OVNKubernetes}
# Check if the OVN_SDN_LIVE_MIGRATION_TIMEOUT environment variable is set and is equal to "0s"
if [ -n "$OVN_SDN_LIVE_MIGRATION_TIMEOUT" ] && [ "$OVN_SDN_LIVE_MIGRATION_TIMEOUT" = "0s" ]; then
  unset OVN_SDN_LIVE_MIGRATION_TIMEOUT
fi

co_timeout=${OVN_SDN_LIVE_MIGRATION_TIMEOUT:-1200s}
timeout "$co_timeout" bash <<EOT
until
  oc wait co --all --for='condition=AVAILABLE=True' --timeout=10s && \
  oc wait co --all --for='condition=PROGRESSING=False' --timeout=10s && \
  oc wait co --all --for='condition=DEGRADED=False' --timeout=10s;
do
  sleep 10
  log "Some ClusterOperators Degraded=False,Progressing=True,or Available=False";
done
EOT

wget -O /tmp/go1.21.5.linux-amd64.tar.gz https://go.dev/dl/go1.21.5.linux-amd64.tar.gz
tar -C /tmp/ -xzf /tmp/go1.21.5.linux-amd64.tar.gz
export PATH=$PATH:/tmp/go/bin

git clone --depth 1 https://github.com/martinkennelly/origin -b live-migration-suite-e2e /tmp/origin
pushd /tmp/origin &>/dev/null
make
export TEST_SDN_LIVE_MIGRATION_OPTIONS=target-cni=OVNKubernetes
./openshift-tests run openshift/network/live-migration -o "${ARTIFACT_DIR}/e2e.log" --junit-dir "${ARTIFACT_DIR}/junit"
popd &>/dev/null
#
#log "Starting openshift-tests monitors"
#openshift-tests run-monitor --artifact-dir "${STORE_PATH}" > "${ARTIFACT_DIR}/run-monitor.log" 2>&1 &
#
#log "Starting live migration"
#oc patch network.config.openshift.io cluster --type='merge' --patch "{\"metadata\":{\"annotations\":{\"network.openshift.io/live-migration\":\"\"}},\"spec\":{\"networkType\":\"${TARGET}\"}}"
#
#log "Waiting for live migration to finish"
#time wait_for_network_config_conditions "6000" "NetworkTypeMigrationInProgress=False" \
# "NetworkTypeMigrationMTUReady=Unknown" \
# "NetworkTypeMigrationTargetCNIAvailable=Unknown" \
# "NetworkTypeMigrationTargetCNIInUse=Unknown" \
# "NetworkTypeMigrationOriginalCNIPurged=Unknown"


# Check all cluster operators back to normal. requires the main check on clusteroperator
# status to succeed 3 times in a row with 30s pause in between checks
all_co_timeout=${OVN_SDN_LIVE_MIGRATION_TIMEOUT:-2700s}
# shellcheck disable=SC2034
success_count=0

timeout "$all_co_timeout" bash <<EOT
until [ \$success_count -eq 3 ]; do
  if oc wait co --all --for='condition=Available=True' --timeout=10s &&
     oc wait co --all --for='condition=Progressing=False' --timeout=10s &&
     oc wait co --all --for='condition=Degraded=False' --timeout=10s; then
    echo "Check succeeded (\$success_count/3)"
    ((success_count++))
    if [ \$success_count -lt 3 ]; then
      echo "Pausing for 30 seconds before the next check..."
      sleep 30
    fi
  else
    echo "Some ClusterOperators Degraded=False, Progressing=True, or Available=False"
    success_count=0
    sleep 10
  fi
done
echo "All checks passed successfully 3 times in a row."
EOT

oc get co