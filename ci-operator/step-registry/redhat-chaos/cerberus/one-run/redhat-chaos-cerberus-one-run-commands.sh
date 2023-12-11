#!/bin/bash

set -o errexit
set -o nounset
set -o pipefail
set -x

ls 

export CERBERUS_KUBECONFIG=$KUBECONFIG

# We will monitor all namespaces if any pods are in a failure state
# Cerberus will also monitor many more components, see full list here:
# https://github.com/redhat-chaos/cerberus#what-kubernetesopenshift-components-can-cerberus-monitor
export CERBERUS_WATCH_NAMESPACES="[^.*$]"

# We will ignore any installer pods, redhat-operator, certified-operators and collect-profiles as those pods restart consistently and cause false failures
# We also want to ignore kube-burner pods as these should already be verified in test steps 
export CERBERUS_IGNORE_PODS="[^installer*,^kube-burner*,^redhat-operators*,^certified-operators*,^collect-profiles*,^loki*]"


./cerberus/prow_run.sh

if [[ -f final_cerberus_info.json ]]; then
    replaced_str=$(less final_cerberus_info.json | sed "s/True/0/g" | sed "s/False/1/g" | tr "'" '"' | jq .cluster_health)
else
    replaced_str=1
fi
date
echo "Finished running cerberus scenarios with status: $replaced_str"
exit $replaced_str