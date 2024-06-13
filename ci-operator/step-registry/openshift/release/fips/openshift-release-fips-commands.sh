#!/bin/bash

set -o nounset
set -o errexit
set -o pipefail

getMasterNode() {
    local master_node
    
    master_node=$(oc get node -l node-role.kubernetes.io/master= --no-headers | awk '!/NotReady|SchedulingDisabled/{print $1; exit}')
    if [[ -z $master_node ]]; then
        echo "Error master node name is null!"
        exit 1
    fi
    echo "$master_node"
}

setupNamespace() {
  local namespace=$1

  oc create ns $namespace -o yaml | oc label -f - security.openshift.io/scc.podSecurityLabelSync=false pod-security.kubernetes.io/enforce=privileged pod-security.kubernetes.io/audit=privileged pod-security.kubernetes.io/warn=privileged --overwrite

  if [ $? != 0 ]; then
    echo "Failed to create $namespace namespace."
    exit 1
  fi
  echo "Created $namespace namespace successfully"
}

runScan() {
  # Run the static or dynamic scan
  local namespace=$1
  local master_node=$2
  local payload_pullspec=$3
  local scan_report=$4
  local mode=$5
  local base_command="podman run --privileged -i -v /:/myroot"
  local check_payload_image="registry.ci.openshift.org/ci/check-payload:latest"

  if [[  $mode == "static" ]]; then
    oc -n "$namespace" debug node/"$master_node" -- chroot /host bash -c "$base_command -e REGISTRY_AUTH_FILE=/myroot/var/lib/kubelet/config.json $check_payload_image scan payload -V $MAJOR_MINOR --url $payload_pullspec &> $scan_report"
  elif [[  $mode == "dynamic" ]]; then
    oc -n "$namespace" debug node/"$master_node" -- chroot /host bash -c "$base_command $check_payload_image scan node --root /myroot &> $scan_report"
  else
    echo "Invalid scan mode. Exiting."
    exit 1
  fi
  out=$(oc -n "$namespace" debug node/"$master_node" -- chroot /host bash -c "cat $scan_report")

  res=$(echo "$out" | grep -iE "Successful run" || false)
  scan_flag=false
  if [[ -n $res ]]; then
      scan_flag=true
  fi

  echo $scan_flag
}

# create a privileged namespace
namespace="tmp-fips-scan-payload-$RANDOM"
setupNamespace $namespace

# get a master node
master_node=$(getMasterNode)

# Get pullspec of nightly under test
payload_pullspec="$(oc get clusterversion version -o json | jq -r .status.desired.image)"

static_scan_log_file="/tmp/fips-static-payload-scan.log"
dynamic_scan_log_file="/tmp/fips-dynamic-payload-scan.log"
static_scan_result=$(runScan "$namespace" "$master_node" "$payload_pullspec" "$static_scan_log_file" "static")
dynamic_scan_result=$(runScan "$namespace" "$master_node" "$payload_pullspec" "$dynamic_scan_log_file" "dynamic")

if [[ "$static_scan_result" != "true" ]]; then
  # Print logs if the scan failed
  oc -n "$namespace" debug node/"$master_node" -- chroot /host bash -c "cat $static_scan_log_file"

  echo "FIPS static scan has FAILED"
else
  echo "FIPS static scan has SUCCEEDED"
fi

if [[ "$dynamic_scan_result" != "true" ]]; then
  # Print logs if the scan failed
  oc -n "$namespace" debug node/"$master_node" -- chroot /host bash -c "cat $dynamic_scan_log_file"

  echo "FIPS dynamic scan has FAILED"
else
  echo "FIPS dynamic scan has SUCCEEDED"
fi

oc delete ns $namespace || true

if [[ "$static_scan_result" != "true" ]] || [[ "$dynamic_scan_result" != "true" ]]; then
  echo "FIPS job has failed. Exiting."
  exit 1
fi
