#!/bin/bash

set -o nounset
set -o errexit
set -o pipefail

CONFIG="${SHARED_DIR}/install-config.yaml"

if [[ "$AWS_DEDICATED_HOST_APPLY_TO" == *"compute"* ]]; then
  echo "Patching compute[0].platform.aws.hostPlacement.affinity = DedicatedHost ..."
  yq-v4 -i eval '.compute[0].platform.aws.hostPlacement.affinity = "DedicatedHost"' ${CONFIG}
fi

if [[ "$AWS_DEDICATED_HOST_APPLY_TO" == *"controlPlane"* ]]; then
  echo "Patching controlPlane.platform.aws.hostPlacement.affinity = DedicatedHost ..."
  yq-v4 -i eval '.controlPlane.platform.aws.hostPlacement.affinity = "DedicatedHost"' ${CONFIG}
fi

if [[ "$AWS_DEDICATED_HOST_APPLY_TO" == *"default"* ]]; then
  echo "Patching defaultMachinePlatform.hostPlacement.affinity = DedicatedHost ..."
  yq-v4 -i eval '.platform.aws.defaultMachinePlatform.hostPlacement.affinity = "DedicatedHost"' ${CONFIG}
fi

# Pre-allocated DH

DH_INFO=${SHARED_DIR}/selected_dedicated_hosts_controlplane.json
if [ -s "$DH_INFO" ]; then

  dh_out=/tmp/ic_dh.yaml
  jq -r '.Hosts[] | "- id: \(.HostId)\n  zone: \(.AvailabilityZone)"' "$DH_INFO" > "$dh_out"

  dh_az_out=/tmp/ic_dh_az.yaml
  jq -r '.Hosts[] | "- \(.AvailabilityZone)"' "$DH_INFO" > "$dh_az_out"

  export dh_out
  export dh_az_out
  instance_type=$(jq -r '.Hosts[0].HostProperties.InstanceType' "$DH_INFO")
  export instance_type

  echo "-----------------------------------------------------------------------------------------"
  echo "Patching dedicatedHost on controlPlane node ..."
  echo "WARN: Zones and instance type will be overridden in order to match the DH configuration."
  echo "-----------------------------------------------------------------------------------------"

  echo "Dedicated Host configuration:"
  cat $dh_out

  yq-v4 -i eval '.controlPlane.platform.aws.hostPlacement.dedicatedHost = load(env(dh_out))' "$CONFIG"
  yq-v4 -i eval '.controlPlane.platform.aws.zones = load(env(dh_az_out))' ${CONFIG}
  yq-v4 -i eval '.controlPlane.platform.aws.type = env(instance_type)' ${CONFIG}
fi

DH_INFO=${SHARED_DIR}/selected_dedicated_hosts_compute.json
if [ -s "$DH_INFO" ]; then
  dh_out=/tmp/ic_dh.yaml
  jq -r '.Hosts[] | "- id: \(.HostId)\n  zone: \(.AvailabilityZone)"' "$DH_INFO" > "$dh_out"

  dh_az_out=/tmp/ic_dh_az.yaml
  jq -r '.Hosts[] | "- \(.AvailabilityZone)"' "$DH_INFO" > "$dh_az_out"

  export dh_out
  export dh_az_out
  instance_type=$(jq -r '.Hosts[0].HostProperties.InstanceType' "$DH_INFO")
  export instance_type

  echo "-----------------------------------------------------------------------------------------"
  echo "Patching dedicatedHost on compute node ..."
  echo "WARN: Zones and instance type will be overridden in order to match the DH configuration."
  echo "-----------------------------------------------------------------------------------------"

  echo "Dedicated Host configuration:"
  cat $dh_out

  yq-v4 -i eval '.compute[0].platform.aws.hostPlacement.dedicatedHost = load(env(dh_out))' "$CONFIG"
  yq-v4 -i eval '.compute[0].platform.aws.zones = load(env(dh_az_out))' ${CONFIG}
  yq-v4 -i eval '.compute[0].platform.aws.type = env(instance_type)' ${CONFIG}
fi

DH_INFO=${SHARED_DIR}/selected_dedicated_hosts_default.json
if [ -s "$DH_INFO" ]; then
  dh_out=/tmp/ic_dh.yaml
  jq -r '.Hosts[] | "- id: \(.HostId)\n  zone: \(.AvailabilityZone)"' "$DH_INFO" > "$dh_out"

  dh_az_out=/tmp/ic_dh_az.yaml
  jq -r '.Hosts[] | "- \(.AvailabilityZone)"' "$DH_INFO" > "$dh_az_out"

  export dh_out
  export dh_az_out
  instance_type=$(jq -r '.Hosts[0].HostProperties.InstanceType' "$DH_INFO")
  export instance_type


  echo "-----------------------------------------------------------------------------------------"
  echo "Patching dedicatedHost on defaultMachinePlatform ..."
  echo "WARN: Zones and instance type will be overridden in order to match the DH configuration."
  echo "-----------------------------------------------------------------------------------------"

  echo "Dedicated Host configuration:"
  cat $dh_out

  yq-v4 -i eval '.platform.aws.defaultMachinePlatform.hostPlacement.dedicatedHost = load(env(dh_out))' "$CONFIG"

  yq-v4 -i eval '.platform.aws.defaultMachinePlatform.zones = load(env(dh_az_out))' ${CONFIG}
  yq-v4 -i eval '.platform.aws.defaultMachinePlatform.type = env(instance_type)' ${CONFIG}

  if [[ "$AWS_DEDICATED_HOST_APPLY_TO" != *"compute"* ]]; then
    echo "WARN: DH is applied to default machine pool, but not compute nodes, removing zones and type from compute nodes"
    yq-v4 -i 'del(.compute[0].platform.aws.zones)' ${CONFIG}
    yq-v4 -i 'del(.compute[0].platform.aws.type)' ${CONFIG}
  fi

  if [[ "$AWS_DEDICATED_HOST_APPLY_TO" != *"controlPlane"* ]]; then
    echo "WARN: DH is applied to default machine pool, but not controlPlane nodes, removing zones and type from controlPlane nodes"
    yq-v4 -i 'del(.controlPlane.platform.aws.zones)' ${CONFIG}
    yq-v4 -i 'del(.controlPlane.platform.aws.type)' ${CONFIG}
  fi
fi

echo "install-config.yaml:"
yq-v4 '({"compute": .compute, "controlPlane": .controlPlane, "platform": .platform})' "${CONFIG}"
