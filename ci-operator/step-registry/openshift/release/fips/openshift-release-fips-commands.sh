#!/bin/bash

set -o nounset
set -o errexit
set -o pipefail

function run_command() {
    local CMD="$1"
    echo "Running Command: ${CMD}"
    eval "${CMD}"
}

pass=false

# get a master node
master_node_0=$(oc get node -l node-role.kubernetes.io/master= --no-headers | grep -Ev "NotReady|SchedulingDisabled"| awk '{print $1}' | awk 'NR==1{print}')
if [[ -z $master_node_0 ]]; then
    echo "Error master node0 name is null!"
fi

# create a ns
namespace="fips-scan-payload-$RANDOM"
run_command "oc create ns $namespace -o yaml | oc label -f - security.openshift.io/scc.podSecurityLabelSync=false pod-security.kubernetes.io/enforce=privileged pod-security.kubernetes.io/audit=privileged pod-security.kubernetes.io/warn=privileged --overwrite"

if [ $? == 0 ]; then
    echo "create $namespace namespace successfully"
else
    echo "Fail to create $namespace namespace."
fi

payload_pullspec=$(oc get clusterversion version -o json | jq -r .status.desired.image)

# run node scan and check the result
report="/tmp/fips-check-payload-scan.log"

# REGISTRY_AUTH_FILE use the location of kublets default pull secret
oc -n $namespace debug node/"$master_node_0" -- chroot /host bash -c "podman run --privileged -i -v /:/myroot -e REGISTRY_AUTH_FILE=/myroot/var/lib/kubelet/config.json registry.ci.openshift.org/ci/check-payload:latest scan payload -V $MAJOR_MINOR --url $payload_pullspec &> $report" || true
out=$(oc -n $namespace debug node/"$master_node_0" -- chroot /host bash -c "cat /$report" || true)
echo "The report is: $out"
oc delete ns $namespace || true
res=$(echo "$out" | grep -iE 'Successful run' || true)
echo "The result is: $res"
if [[ -n $res ]];then
    pass=true
fi

if $pass; then
    exit 0
else
    exit 1
fi
