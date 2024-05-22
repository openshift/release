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
supported_versions=(
  "4.12"
  "4.13"
  "4.14"
  "4.15"
  "4.16"
  "4.17"
)

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


payload_pullspec=$(oc get clusterversion version -o json | jq -r .status.desired.image)
major_minor=$(oc get clusterversion version -o json | jq -r .status.desired.version | cut -d"." -f1-2)

# Check if major_minor is a version we care about
found=0
for version in "${supported_versions[@]}"; do
  if [ "${major_minor}" == "${version}" ]; then
    found=1
    break
  fi
done

if [ $found -eq 0 ]; then
  echo "${major_minor} is not in the list of supported versions ${supported_versions[*]}"
  exit 1
fi

# run node scan and check the result
report="/tmp/fips-check-payload-scan.log"

# REGISTRY_AUTH_FILE use the location of kublets default pull secret
oc -n $namespace debug node/"$master_node_0" -- chroot /host bash -c "podman run --privileged -i -v /:/myroot -e REGISTRY_AUTH_FILE=/myroot/var/lib/kubelet/config.json registry.ci.openshift.org/ci/check-payload:latest scan payload -V $major_minor --url $payload_pullspec &> $report" || true
out=$(oc -n $namespace debug node/"$master_node_0" -- chroot /host bash -c "cat /$report" || true)
echo "The report is: $out"
oc delete ns $namespace || true
res=$(echo "$out" | grep -E 'Failure Report|Successful run with warnings|Warning Report' || true)
echo "The result is: $res"
if [[ -n $res ]];then
    pass=false
fi

if $pass; then
    exit 0
else
    exit 1
fi
