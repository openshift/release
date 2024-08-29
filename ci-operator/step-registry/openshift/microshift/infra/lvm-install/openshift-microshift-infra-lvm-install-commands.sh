#!/bin/bash
set -xeuo pipefail

curl https://raw.githubusercontent.com/openshift/release/master/ci-operator/step-registry/openshift/microshift/includes/openshift-microshift-includes-commands.sh -o /tmp/ci-functions.sh
# shellcheck disable=SC1091
source /tmp/ci-functions.sh
ci_script_prologue

device="/dev/xvdc"

if [[ "${EC2_INSTANCE_TYPE%.*}" =~ .*"g".* || "${EC2_INSTANCE_TYPE%.*}" =~ "t3".* || "${EC2_INSTANCE_TYPE%.*}" =~ c7i.2xlarge ]]; then
  # Sometimes, devices are in different order and nvme1 stores OS while nvme0 should hold LVM for topolvm.
  # If /dev/nvme0 is already partitioned (operating system), then use nvme1 for lvm.
  # If `partx /dev/nvme0n1` fails (rc=1), it couldn't read partition table, so it's the one to use for lvm.
  if ssh "${INSTANCE_PREFIX}" "sudo partx /dev/nvme0n1"; then
    device="/dev/nvme1n1"
  else
    device="/dev/nvme0n1"
  fi
fi

ssh "${INSTANCE_PREFIX}" "lsblk ; sudo dnf install -y lvm2 && sudo pvcreate ${device} && sudo vgcreate rhel ${device}"
