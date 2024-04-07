#!/bin/bash

set -o nounset
set -o errexit
set -o pipefail

function run_command() {
    local CMD="$1"
    echo "Running Command: ${CMD}"
    eval "${CMD}"
}

pass=true

# get a master node
master_node_0=$(oc get node -l node-role.kubernetes.io/master= --no-headers | grep -Ev "NotReady|SchedulingDisabled"| awk '{print $1}' | awk 'NR==1{print}')
if [[ -z $master_node_0 ]]; then
    echo "Error master node0 name is null!"
    pass=false
fi
# create a ns
namespace="fips-scan-payload-$RANDOM"
run_command "oc create ns $namespace -o yaml | oc label -f - security.openshift.io/scc.podSecurityLabelSync=false pod-security.kubernetes.io/enforce=privileged pod-security.kubernetes.io/audit=privileged pod-security.kubernetes.io/warn=privileged --overwrite"

if [ $? == 0 ]; then
    echo "create $namespace namespace successfully"
else
    echo "Fail to create $namespace namespace."
    pass=false
fi

payload_url="${RELEASE_IMAGE_LATEST}"

if [[ "$payload_url" == *"@sha256"* ]]; then
    payload_url=$(echo "$payload_url" | sed 's/@sha256.*/:latest/')
fi


echo "Setting runtime dir"
mkdir -p /tmp/.docker/ ${XDG_RUNTIME_DIR}

echo "Login to registry"
oc registry login --to /tmp/.docker/config.json

export KUBECONFIG=/tmp/.docker/config.json

# run node scan and check the result
report="/tmp/fips-check-payload-scan.log"
oc --request-timeout=300s -n "$namespace" debug node/"$master_node_0" -- chroot /host bash -c "podman run --authfile /var/lib/kubelet/config.json --privileged -i -v /:/myroot registry.ci.openshift.org/ci/check-payload:latest scan payload -V $MAJOR_MINOR --url $payload_url &> $report" || true
out=$(oc --request-timeout=300s -n "$namespace" debug node/"$master_node_0" -- chroot /host bash -c "cat /$report" || true)
echo "The report is: $out"
oc delete ns $namespace || true
res=$(echo "$out" | grep -E 'Failure Report|Successful run with warnings|Warning Report' || true)
echo "The result is: $res"
if [[ -n $res ]];then
    echo "The result is: $res"
    pass=false
fi

if $pass; then
    exit 0
else
    exit 1
fi
