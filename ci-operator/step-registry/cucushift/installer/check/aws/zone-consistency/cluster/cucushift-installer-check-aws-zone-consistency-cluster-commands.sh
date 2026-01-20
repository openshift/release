#!/bin/bash

set -o nounset
set -o errexit
set -o pipefail

# save the exit code for junit xml file generated in step gather-must-gather
# post check steps after cluster installation, exit code 101 if failed,
# save to install-post-check-status.txt
EXIT_CODE=101
trap 'if [[ "$?" == 0 ]]; then EXIT_CODE=0; fi; echo "${EXIT_CODE}" > "${SHARED_DIR}/install-post-check-status.txt"' EXIT TERM

if [ -f "${SHARED_DIR}/kubeconfig" ] ; then
  export KUBECONFIG="${SHARED_DIR}/kubeconfig"
else
  echo "No KUBECONFIG found, exit now"
  exit 1
fi

MASTER_MACHINES=$(oc get machine -n openshift-machine-api -l machine.openshift.io/cluster-api-machine-role=master -o jsonpath='{.items[*].metadata.name}' 2>/dev/null || echo "")

if [ -z "$MASTER_MACHINES" ]; then
  echo "No master machines found"
  exit 1
fi

ret=0

for machine in $MASTER_MACHINES; do
  zone_label=$(oc get machine "$machine" -n openshift-machine-api -o jsonpath='{.metadata.labels.machine\.openshift\.io/zone}' 2>/dev/null || echo "")
  provider_id=$(oc get machine "$machine" -n openshift-machine-api -o jsonpath='{.spec.providerID}' 2>/dev/null || echo "")
  provider_zone=$(echo "$provider_id" | grep -oP 'aws:///\K[^/]+' 2>/dev/null || echo "")
  spec_zone=$(oc get machine "$machine" -n openshift-machine-api -o jsonpath='{.spec.providerSpec.value.placement.availabilityZone}' 2>/dev/null || echo "")
  
  if [ -z "$zone_label" ] || [ -z "$provider_zone" ] || [ -z "$spec_zone" ]; then
    echo "ERROR: $machine - missing zone information (label: $zone_label, providerID: $provider_zone, spec: $spec_zone)"
    ret=$((ret + 1))
  elif [ "$zone_label" != "$provider_zone" ] || [ "$provider_zone" != "$spec_zone" ]; then
    echo "ERROR: $machine - zone inconsistent (label: $zone_label, providerID: $provider_zone, spec: $spec_zone)"
    ret=$((ret + 1))
  fi
done

if [ $ret -eq 0 ]; then
  echo "PASS: All machines have consistent zones"
else
  echo "FAIL: Machines with inconsistent zones detected"
fi

exit $ret
