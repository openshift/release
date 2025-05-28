#!/bin/bash

set -o errexit
set -o nounset
set -o pipefail
set -x

if [ ${RUN_CERBERUS} == "false" ]; then
  exit 0
fi

ls

export CERBERUS_KUBECONFIG=$KUBECONFIG

# We will monitor all namespaces if any pods are in a failure state
# Cerberus will also monitor many more components, see full list here:
# https://github.com/redhat-chaos/cerberus#what-kubernetesopenshift-components-can-cerberus-monitor
export CERBERUS_WATCH_NAMESPACES="[^.*$]"

# We will ignore any installer pods, redhat-operator, certified-operators and collect-profiles as those pods restart consistently and cause false failures
# We also want to ignore kube-burner pods as these should already be verified in test steps 
DEFAULT_IGNORE_PODS="[^installer*,^kube-burner*,^redhat-operators*,^certified-operators*,^collect-profiles*,^loki*]"
DEFAULT_IGNORE_PODS="${DEFAULT_IGNORE_PODS#[}"
DEFAULT_IGNORE_PODS="${DEFAULT_IGNORE_PODS%]}"

# Merge default and user provided ignore list
if [ -n "$CERBERUS_USER_IGNORE_PODS" ] && [ "$CERBERUS_USER_IGNORE_PODS" != "[]" ]; then
  CERBERUS_USER_IGNORE_PODS="${CERBERUS_USER_IGNORE_PODS#[}"
  CERBERUS_USER_IGNORE_PODS="${CERBERUS_USER_IGNORE_PODS%]}"
  CERBERUS_IGNORE_PODS="[$DEFAULT_IGNORE_PODS,$CERBERUS_USER_IGNORE_PODS]"
else
  CERBERUS_IGNORE_PODS="[$DEFAULT_IGNORE_PODS]"
fi

export CERBERUS_IGNORE_PODS

./cerberus/prow_run.sh

if [[ -f final_cerberus_info.json ]]; then
    replaced_str=$(less final_cerberus_info.json | sed "s/True/0/g" | sed "s/False/1/g" | tr "'" '"' | jq .cluster_health)
else
    replaced_str=1
fi
date
echo "Finished running cerberus scenarios with status: $replaced_str"
exit $replaced_str