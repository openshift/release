#!/bin/bash

set -o errexit
set -o nounset
set -o pipefail

if [[ "${CLUSTER_TYPE}" == "aws-arm64" ]] || [[ "${OCP_ARCH}" == "arm64" ]]; then
    DEFAULT_AWS_INSANCE_TYPE="m6gd.2xlarge"
else
    DEFAULT_AWS_INSANCE_TYPE="m5d.2xlarge"
fi

SINGLE_NODE_AWS_INSTANCE_TYPE="${SINGLE_NODE_AWS_INSTANCE_TYPE:-${DEFAULT_AWS_INSANCE_TYPE}}"

echo "Updating install-config.yaml to a single ${SINGLE_NODE_AWS_INSTANCE_TYPE} control plane node and 0 workers"

# RHEL9 based images do not contain pip3, we need to install it. Multiple jobs rely on the installer image
# so simply using something like upi-installer will break things since some jobs use stable payload which
# does not include upi-installer.
OS_VER=$(awk -F= '/^VERSION_ID=/ { print $2 }' /etc/os-release | tr -d '"' | cut -f1 -d'.')
if [[ ${OS_VER} == "9" ]]; then
    echo "Detected RHEL9, installing pip"
    curl -L -o /tmp/get-pip.py -w "\nStatus Code: %{http_code}\n" https://bootstrap.pypa.io/get-pip.py
    python /tmp/get-pip.py
    export PATH=$PATH:$HOME/.local/bin
fi


pip3 install pyyaml==6.0 --user
python3 -c '
import yaml
import sys

input_file = sys.argv[1]
output_file = sys.argv[2] if len(sys.argv) == 3 else sys.argv[1]  # Output in-place if destination not given

with open(input_file) as f:
    cfg = yaml.safe_load(f)

# Some workflows do not define controlPlane in install-config.yaml
if not "controlPlane" in cfg:
  cfg["controlPlane"] = {}

cfg["controlPlane"]["replicas"] = 1

if not "networking" in cfg:
    cfg["networking"] = {}

cfg["networking"]["networkType"] = "'${NETWORK_TYPE}'"

# Single Node Openshift requires extra memory and compute resources
platform = cfg["controlPlane"]["platform"]
if "aws" in platform:
    platform["aws"]["type"] = "'${SINGLE_NODE_AWS_INSTANCE_TYPE}'"
else:
    raise ValueError("This step only applies to AWS, please use the correct step for your platform")

# Some workflows do not define any compute machine pools in install-config.yaml
if not "compute" in cfg:
    cfg["compute"] = [
        {
            "name": "worker",
            "platform": {},
        }
    ]

for machine_pool in cfg["compute"]:
    machine_pool["replicas"] = 0

with open(output_file, "w") as f:
    yaml.safe_dump(cfg, f)
' "${SHARED_DIR}/install-config.yaml"

