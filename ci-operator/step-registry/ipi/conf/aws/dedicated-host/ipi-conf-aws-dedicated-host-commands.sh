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

DEDICATED_HOSTS_INFO=${SHARED_DIR}/selected_dedicated_hosts.json
if [ -f "$DEDICATED_HOSTS_INFO" ]; then

  echo "======================================================================"
  echo "Found pre-acclocated DH: selected_dedicated_hosts.json"
  echo ""
  echo "WARNINNG: AWS Dedicated Host will overide the following configuration:"
  echo "platform.aws.zones for compute and controlPlane"
  echo "platform.aws.type for compute and controlPlane"
  echo "======================================================================"

  DEDICATED_HOST_OUT=/tmp/ic_dh.yaml
  jq -r '.Hosts[] | "- id: \(.HostId)\n  zone: \(.AvailabilityZone)"' "$DEDICATED_HOSTS_INFO" > "$DEDICATED_HOST_OUT"

  DEDICATED_HOST_AZ_OUT=/tmp/ic_dh_az.yaml
  jq -r '.Hosts[] | "- \(.AvailabilityZone)"' "$DEDICATED_HOSTS_INFO" > "$DEDICATED_HOST_AZ_OUT"

  export DEDICATED_HOST_OUT
  export DEDICATED_HOST_AZ_OUT
  instance_type=$(jq -r '.Hosts[0].HostProperties.InstanceType' "$DEDICATED_HOSTS_INFO")
  export instance_type

  echo "Dedicated Host configuration:"
  cat $DEDICATED_HOST_OUT

  if [[ "$AWS_DEDICATED_HOST_APPLY_TO" == *"compute"* ]]; then
    echo "Patching dedicatedHost on compute node ..."
    yq-v4 -i eval '.compute[0].platform.aws.hostPlacement.dedicatedHost = load(env(DEDICATED_HOST_OUT))' "$CONFIG"

    echo "Overriding AZ and instance type on compute node ..."
    yq-v4 -i eval '.compute[0].platform.aws.zones = load(env(DEDICATED_HOST_AZ_OUT))' ${CONFIG}
    yq-v4 -i eval '.compute[0].platform.aws.type = env(instance_type)' ${CONFIG}
  fi

  if [[ "$AWS_DEDICATED_HOST_APPLY_TO" == *"controlPlane"* ]]; then
    echo "Patching dedicatedHost on controlPlane node ..."
    yq-v4 -i eval '.controlPlane.platform.aws.hostPlacement.dedicatedHost = load(env(DEDICATED_HOST_OUT))' "$CONFIG"

    echo "Overriding AZ and instance type on controlPlane node ..."
    yq-v4 -i eval '.controlPlane.platform.aws.zones = load(env(DEDICATED_HOST_AZ_OUT))' ${CONFIG}
    yq-v4 -i eval '.controlPlane.platform.aws.type = env(instance_type)' ${CONFIG}
  fi

  if [[ "$AWS_DEDICATED_HOST_APPLY_TO" == *"default"* ]]; then
    echo "Patching dedicatedHost on defaultMachinePlatform ..."
    yq-v4 -i eval '.platform.aws.defaultMachinePlatform.hostPlacement.dedicatedHost = load(env(DEDICATED_HOST_OUT))' "$CONFIG"

    echo "Overriding AZ and instance type on controlPlane and compute nodes ..."
    yq-v4 -i eval '.compute[0].platform.aws.zones = load(env(DEDICATED_HOST_AZ_OUT))' ${CONFIG}
    yq-v4 -i eval '.compute[0].platform.aws.type = env(instance_type)' ${CONFIG}

    yq-v4 -i eval '.controlPlane.platform.aws.zones = load(env(DEDICATED_HOST_AZ_OUT))' ${CONFIG}
    yq-v4 -i eval '.controlPlane.platform.aws.type = env(instance_type)' ${CONFIG}

  fi
fi

echo "install-config.yaml:"
yq-v4 '({"compute": .compute, "controlPlane": .controlPlane, "platform": .platform})' "${CONFIG}"
