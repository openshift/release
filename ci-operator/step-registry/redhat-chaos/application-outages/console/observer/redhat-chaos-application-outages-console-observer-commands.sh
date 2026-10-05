#!/bin/bash
set -o errexit
set -o nounset
set -o pipefail
set -x
cat /etc/os-release
oc config view
oc projects
python3 --version
ls

while [ ! -f "${KUBECONFIG}" ]; do
  printf "%s: waiting for %s\n" "$(date --utc --iso=s)" "${KUBECONFIG}"
  sleep 30
done
printf "%s: acquired %s\n" "$(date --utc --iso=s)" "${KUBECONFIG}"

echo "kubeconfig loc $KUBECONFIG"

echo "kubeconfig loc $$KUBECONFIG"
echo "Using the flattened version of kubeconfig"
oc config view --flatten > /tmp/config
export KUBECONFIG=/tmp/config

export KRKN_KUBE_CONFIG=$KUBECONFIG
export NAMESPACE=$TARGET_NAMESPACE

while [ "$(oc get ns | grep -c 'start-kraken')" -lt 1 ]; do
  echo "start kraken not found yet, waiting"
  sleep 10
done

if [[ $IF_CHECK_NETWORK_TYPE == "true" ]];then
   while [ "$(oc get network.config.openshift.io cluster -o jsonpath='{.status.networkType}')" != "OVNKubernetes" ]; do
       echo "The network is still SDN, not migrate CNI to OVN from SDN "
       sleep 30
   done
fi

./application-outages/prow_run.sh
rc=$?

if [[ $TELEMETRY_EVENTS_BACKUP == "True" ]]; then
    cp /tmp/events.json ${ARTIFACT_DIR}/events.json
fi
echo "Finished running application outages scenarios"
echo "Return code: $rc"
